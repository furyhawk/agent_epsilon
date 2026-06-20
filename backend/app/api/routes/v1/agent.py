"""AI Agent WebSocket route.

The route is just lifecycle plumbing — auth, accept, dispatch loop, disconnect.
Per-turn orchestration lives in :class:`app.services.agent_session.AgentSession`.
"""

import logging
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from pydantic_ai import (
    FinalResultEvent,
    FunctionToolCallEvent,
    FunctionToolResultEvent,
    PartDeltaEvent,
    PartStartEvent,
    TextPartDelta,
)
from pydantic_ai.messages import TextPart
from pydantic_ai_backends import StateBackend

from app.agents.pydantic_deep_assistant import PydanticDeepContext, get_agent
from app.api.deps import get_conversation_service, get_current_user_ws, get_project_service
from app.core.config import settings
from app.db.models.user import User
from app.db.session import get_db_context
from app.schemas.conversation import ConversationCreate, MessageCreate
from app.services.agent import AgentConnectionManager, send_event
from app.services.agent_session import AgentSession

logger = logging.getLogger(__name__)

router = APIRouter()

manager = AgentConnectionManager()


@router.get("/agent/models")
async def list_models() -> dict[str, Any]:
    """Return available LLM models and the current default."""
    return {
        "default": settings.AI_MODEL,
        "models": settings.AI_AVAILABLE_MODELS,
    }


@router.websocket("/ws/agent")
async def agent_websocket(
    websocket: WebSocket,
    user: User = Depends(get_current_user_ws),
) -> None:
    """WebSocket endpoint for the AI agent.

    Streams agent events to the client. Each incoming JSON message is forwarded to
    :class:`AgentSession.process_message`.

    Expected input format::

        {
            "message": "user message here",
            "file_ids": ["..."],
            "conversation_id": "optional-uuid",
            "model": "optional-model-override",
            "thinking_effort": "optional"
        }

    Authentication: handled by ``get_current_user_ws`` (JWT).
    """
    if user is None:
        return

    await manager.connect(websocket)
    session = AgentSession(
        websocket,
        user,
    )

    try:
        while True:
            try:
                data = await websocket.receive_json()
            except WebSocketDisconnect:
                break
            await session.handle_frame(data)
    finally:
        await session.shutdown()
        manager.disconnect(websocket)


@router.websocket("/ws/projects/{project_id}/chats/{conversation_id}")
async def project_chat_websocket(
    project_id: UUID,
    conversation_id: UUID,
    websocket: WebSocket,
    user: User = Depends(get_current_user_ws),
) -> None:
    """WebSocket endpoint for project-scoped PydanticDeep chat.

    One Docker container per project is shared across all chats.
    Chat history is stored per-chat inside the project volume at:
      .pydantic-deep/sessions/{conversation_id}/messages.json
    """

    await manager.connect(websocket)

    context: PydanticDeepContext = {}
    context["user_id"] = str(user.id) if user else None
    context["user_name"] = user.email if user else None

    try:
        # Verify project access
        async with get_db_context() as db:
            project_service = get_project_service(db)
            try:
                await project_service.get(project_id, user_id=user.id)
            except Exception as exc:
                await websocket.close(code=4003, reason=str(exc))
                return

        backend: Any = StateBackend()

        assistant = get_agent(
            conversation_id=str(conversation_id),
            backend_override=backend,
            history_messages_path=f".pydantic-deep/sessions/{conversation_id}/messages.json",
        )

        # Ensure the conversation record exists and is linked to the project
        async with get_db_context() as db:
            conv_service = get_conversation_service(db)
            try:
                await conv_service.get_conversation(conversation_id, user_id=user.id)
            except Exception:
                conv = await conv_service.create_conversation(
                    ConversationCreate(
                        user_id=user.id,
                        project_id=project_id,
                    )
                )
                await send_event(
                    websocket,
                    "conversation_created",
                    {"conversation_id": str(conv.id), "project_id": str(project_id)},
                )

        while True:
            data = await websocket.receive_json()
            user_message = data.get("message", "")

            if not user_message:
                await send_event(websocket, "error", {"message": "Empty message"})
                continue

            await send_event(websocket, "user_prompt", {"content": user_message})

            async with get_db_context() as db:
                conv_service = get_conversation_service(db)
                try:
                    await conv_service.add_message(
                        conversation_id,
                        MessageCreate(role="user", content=user_message),
                    )
                except Exception as exc:
                    logger.warning("Failed to persist user message: %s", exc)

            try:
                await send_event(websocket, "model_request_start", {})

                async with assistant.agent.run_stream(user_message, deps=assistant.deps) as stream:
                    async for event in stream.stream_events():
                        if isinstance(event, PartDeltaEvent) and isinstance(
                            event.delta, TextPartDelta
                        ):
                            await send_event(
                                websocket, "text_delta", {"delta": event.delta.content_delta}
                            )
                        elif isinstance(event, PartStartEvent) and isinstance(event.part, TextPart):
                            pass
                        elif isinstance(event, FunctionToolCallEvent):
                            await send_event(
                                websocket,
                                "tool_call",
                                {
                                    "tool_name": event.part.tool_name,
                                    "args": str(event.part.args),
                                },
                            )
                        elif isinstance(event, FunctionToolResultEvent):
                            await send_event(
                                websocket,
                                "tool_result",
                                {
                                    "tool_name": event.result.tool_name,
                                    "content": str(event.result.content),
                                },
                            )
                        elif isinstance(event, FinalResultEvent):
                            await send_event(
                                websocket, "final_result", {"content": str(event.output)}
                            )

                    result = stream.result()

                async with get_db_context() as db:
                    conv_service = get_conversation_service(db)
                    try:
                        await conv_service.add_message(
                            conversation_id,
                            MessageCreate(
                                role="assistant",
                                content=getattr(result, "output", ""),
                                model_name=getattr(assistant, "model_name", None),
                            ),
                        )
                    except Exception as exc:
                        logger.warning("Failed to persist assistant response: %s", exc)

                await send_event(
                    websocket,
                    "complete",
                    {
                        "conversation_id": str(conversation_id),
                        "project_id": str(project_id),
                    },
                )

            except WebSocketDisconnect:
                logger.info("Client disconnected during project chat")
                break
            except Exception as exc:
                logger.exception("Error in project chat: %s", exc)
                await send_event(websocket, "error", {"message": str(exc)})

    except WebSocketDisconnect:
        pass
    finally:
        manager.disconnect(websocket)
