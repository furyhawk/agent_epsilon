"""LLM-based image description for RAG document processing.

Uses the configured AI framework (PydanticAI, LangChain, etc.) to describe
images extracted from documents. Descriptions are appended to page content
before chunking, making image content searchable via text embeddings.

Configuration:
    RAG_IMAGE_DESCRIPTION_MODEL — LLM model to use (defaults to AI_MODEL from .env)
"""

import base64
import logging
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)

IMAGE_DESCRIPTION_PROMPT = (
    "Describe this image in detail. Focus on any text, data, charts, diagrams, "
    "or visual information that would be useful for document search and retrieval. "
    "Be concise but comprehensive."
)


class BaseImageDescriber(ABC):
    """Abstract base for LLM-based image description."""

    @abstractmethod
    async def describe(self, image_bytes: bytes, mime_type: str = "image/png") -> str:
        """Generate a text description of an image."""


def _b64_encode(image_bytes: bytes) -> str:
    """Base64-encode raw image bytes."""
    return base64.b64encode(image_bytes).decode("utf-8")
