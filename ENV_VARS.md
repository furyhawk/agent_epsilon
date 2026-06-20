# Environment variables

Reference for `agent_epsilon` runtime configuration. The
authoritative source is `backend/.env.example` — this doc explains what each
group is for and which are required vs optional.

> Quick start: copy `backend/.env.example` to `backend/.env` and fill in the
> blanks marked **Required**. Defaults are sensible for local development.

## Project

| Variable | Required | Default | Description |
|---|---|---|---|
| `PROJECT_NAME` | optional | `agent_epsilon` | Used in logs, OpenAPI title, email templates |
| `DEBUG` | optional | `true` | When `true`, FastAPI returns full tracebacks |
| `ENVIRONMENT` | optional | `local` | Free-form tag: `local` / `staging` / `production` |
| `TIMEZONE` | optional | `UTC` | IANA TZ name (e.g. `Europe/Warsaw`) |
| `BACKEND_URL` | optional | `http://localhost:8000` | Used by frontend BFF + email link generation |
| `FRONTEND_URL` | optional | `http://localhost:3000` | Used by password-reset / magic-link emails |

## Auth & secrets

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY` | **required in prod** | (generated) | JWT signing key. Rotating invalidates all tokens |
| `API_KEY` | **required in prod** | (generated) | Static admin/service-to-service key for `X-API-Key` header |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | optional | `30` | JWT access token lifetime |
| `REFRESH_TOKEN_EXPIRE_MINUTES` | optional | `10080` | JWT refresh token lifetime (7 days) |
| `GOOGLE_OAUTH_CLIENT_ID` | required | — | From Google Cloud Console → OAuth credentials |
| `GOOGLE_OAUTH_CLIENT_SECRET` | required | — | jw |

## Database

| Variable | Required | Default | Description |
|---|---|---|---|
| `DATABASE_URL` | **required** | `postgresql+asyncpg://...` | Full async connection string |
| `DB_POOL_SIZE` | optional | `5` | Number of long-lived connections |
| `DB_MAX_OVERFLOW` | optional | `10` | Burst capacity above pool size |

## LLM / AI

| Variable | Required | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | **required** | — | From platform.openai.com |
| `AI_MODEL` | optional | `gpt-5.5` | Default model used by agent (provider-specific) |
| `LOGFIRE_TOKEN` | optional | — | When set, ships traces to Logfire (logfire.pydantic.dev) |

## RAG (qdrant)

| Variable | Required | Default | Description |
|---|---|---|---|
| `QDRANT_URL` | **required** | `http://localhost:6333` | Qdrant REST endpoint |
| `QDRANT_API_KEY` | optional | — | Auth (cloud Qdrant) |

## Redis

| Variable | Required | Default | Description |
|---|---|---|---|
| `REDIS_URL` | **required** | `redis://localhost:6379/0` | Used by cache, rate-limiter, session store |

## Sentry

| Variable | Required | Default | Description |
|---|---|---|---|
| `SENTRY_DSN` | optional (off if empty) | — | From sentry.io project settings |
| `SENTRY_ENVIRONMENT` | optional | `local` | Tag for `environment` filter |
| `SENTRY_TRACES_SAMPLE_RATE` | optional | `0.1` | 0.0–1.0 — perf tracing sample |

## Prometheus

| Variable | Required | Default | Description |
|---|---|---|---|
| `PROMETHEUS_METRICS_PATH` | optional | `/metrics` | URL path where metrics are exposed |
| `PROMETHEUS_AUTH_TOKEN` | optional (off if empty) | — | When set, `/metrics` requires `Authorization: Bearer <token>` |

## Validation

```bash
# Confirm settings load without errors:
cd backend && uv run python -c "from app.core.config import settings; print(settings.model_dump_json(indent=2))"
```

If any **Required** var is missing, FastAPI raises `pydantic_settings.SettingsError` on startup — check the message for which field.
