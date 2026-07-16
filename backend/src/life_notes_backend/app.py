from __future__ import annotations

import inspect
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Dict, Optional

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from .config import Settings
from .middleware import ProtectedAPIMiddleware, RequestBodyLimitMiddleware
from .models import JournalGenerationRequest, JournalGenerationResponse
from .provider import (
    DeepSeekJournalProvider,
    JournalProvider,
    JournalProviderConfigurationError,
    JournalProviderRefusalError,
    JournalProviderResponseError,
    JournalProviderTimeoutError,
    JournalProviderUnavailableError,
)
from .rate_limit import SlidingWindowRateLimiter


LOGGER = logging.getLogger("life_notes_backend")
MAX_API_RESPONSE_BYTES = 65_536


@dataclass(frozen=True)
class APIError(Exception):
    status_code: int
    code: str
    message: str
    headers: Optional[Dict[str, str]] = None


def create_app(
    settings: Optional[Settings] = None,
    provider: Optional[JournalProvider] = None,
    rate_limiter: Optional[SlidingWindowRateLimiter] = None,
) -> FastAPI:
    runtime_settings = settings or Settings.from_env()
    journal_provider = provider or DeepSeekJournalProvider(
        api_key=runtime_settings.require_deepseek_api_key(),
        base_url=runtime_settings.deepseek_base_url,
        model=runtime_settings.deepseek_model,
        timeout_seconds=runtime_settings.deepseek_timeout_seconds,
        max_output_tokens=runtime_settings.deepseek_max_output_tokens,
    )
    limiter = rate_limiter or SlidingWindowRateLimiter(
        limit=runtime_settings.rate_limit_requests_per_minute
    )
    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            close = getattr(journal_provider, "aclose", None)
            if close is not None:
                try:
                    close_result = close()
                    if inspect.isawaitable(close_result):
                        await close_result
                except Exception as error:
                    LOGGER.error(
                        "provider_close_failed error_type=%s",
                        type(error).__name__,
                    )

    app = FastAPI(
        title="Life Notes Backend",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    app.add_middleware(
        RequestBodyLimitMiddleware,
        max_bytes=runtime_settings.max_request_body_bytes,
    )
    app.add_middleware(
        ProtectedAPIMiddleware,
        bearer_token=runtime_settings.bearer_token,
        rate_limiter=limiter,
    )

    @app.exception_handler(APIError)
    async def handle_api_error(_: Request, error: APIError) -> JSONResponse:
        return JSONResponse(
            status_code=error.status_code,
            headers=error.headers,
            content={"error": {"code": error.code, "message": error.message}},
        )

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(
        _: Request,
        error: RequestValidationError,
    ) -> JSONResponse:
        fields = [
            {
                "location": [str(component) for component in item.get("loc", ())],
                "type": item.get("type", "validation_error"),
            }
            for item in error.errors()
        ]
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "invalid_request",
                    "message": "请求格式无效。",
                    "fields": fields,
                }
            },
        )

    @app.exception_handler(Exception)
    async def handle_unexpected_error(request: Request, error: Exception) -> JSONResponse:
        LOGGER.error(
            "unhandled_error path=%s error_type=%s",
            request.url.path,
            type(error).__name__,
        )
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "internal_error", "message": "服务暂时不可用。"}},
        )

    @app.get("/health")
    async def health() -> Dict[str, str]:
        return {"status": "ok"}

    @app.post(
        "/v1/journals/generate",
        response_model=JournalGenerationResponse,
    )
    async def generate_journal(
        generation_request: JournalGenerationRequest,
    ) -> Response:
        try:
            journal = await journal_provider.generate(generation_request)
        except JournalProviderRefusalError:
            LOGGER.info(
                "journal_generation_refused request_id=%s",
                generation_request.request_id,
            )
            raise APIError(422, "generation_refused", "模型无法处理这组素材。")
        except JournalProviderTimeoutError:
            LOGGER.warning(
                "journal_generation_timeout request_id=%s",
                generation_request.request_id,
            )
            raise APIError(504, "provider_timeout", "日记生成超时，请稍后重试。")
        except JournalProviderResponseError:
            LOGGER.warning(
                "journal_generation_invalid_response request_id=%s",
                generation_request.request_id,
            )
            raise APIError(502, "invalid_provider_response", "生成结果格式无效，请重试。")
        except JournalProviderConfigurationError as error:
            LOGGER.error(
                "journal_generation_provider_configuration_error "
                "request_id=%s provider_status=%s",
                generation_request.request_id,
                error.status_code,
            )
            raise APIError(
                424,
                "provider_configuration_error",
                "DeepSeek 配置或请求协议无效，请检查后端配置。",
            )
        except JournalProviderUnavailableError:
            LOGGER.warning(
                "journal_generation_provider_unavailable request_id=%s",
                generation_request.request_id,
            )
            raise APIError(503, "provider_unavailable", "AI 服务暂时不可用。")
        except Exception as error:
            LOGGER.error(
                "journal_generation_failed request_id=%s error_type=%s",
                generation_request.request_id,
                type(error).__name__,
            )
            raise APIError(503, "provider_unavailable", "AI 服务暂时不可用。")

        expected_identifier = f"deepseek.chat-completions.{journal.model}"
        if journal.generator_identifier != expected_identifier:
            LOGGER.warning(
                "journal_generation_invalid_provenance request_id=%s",
                generation_request.request_id,
            )
            raise APIError(502, "invalid_provider_response", "生成结果格式无效，请重试。")
        generation_response = JournalGenerationResponse(
            request_id=generation_request.request_id,
            title=journal.title,
            body=journal.body,
            model=journal.model,
            generator_identifier=journal.generator_identifier,
        )
        encoded_response = generation_response.model_dump_json().encode("utf-8")
        if len(encoded_response) > MAX_API_RESPONSE_BYTES:
            LOGGER.warning(
                "journal_generation_response_too_large request_id=%s",
                generation_request.request_id,
            )
            raise APIError(502, "invalid_provider_response", "生成结果格式无效，请重试。")
        return Response(content=encoded_response, media_type="application/json")

    return app
