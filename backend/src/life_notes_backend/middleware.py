from __future__ import annotations

import asyncio
import hashlib
import secrets
from typing import Dict, Optional

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .rate_limit import SlidingWindowRateLimiter


class ProtectedAPIMiddleware:
    """在读取或解析受保护 API 的 body 前完成认证与限流。"""

    def __init__(
        self,
        app: ASGIApp,
        bearer_token: str,
        rate_limiter: SlidingWindowRateLimiter,
        protected_prefix: str = "/v1/",
    ) -> None:
        self._app = app
        self._credential_digest = hashlib.sha256(bearer_token.encode("utf-8")).digest()
        self._credential_key = self._credential_digest.hex()
        self._rate_limiter = rate_limiter
        self._protected_prefix = protected_prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not scope.get("path", "").startswith(
            self._protected_prefix
        ):
            await self._app(scope, receive, send)
            return

        async def send_without_storage(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = [
                    (key, value)
                    for key, value in message.get("headers", [])
                    if key.lower() not in (b"cache-control", b"pragma")
                ]
                headers.extend(
                    [
                        (b"cache-control", b"no-store"),
                        (b"pragma", b"no-cache"),
                    ]
                )
                message = {**message, "headers": headers}
            await send(message)

        authorization = _headers(scope).get("authorization", "")
        scheme, separator, token = authorization.partition(" ")
        token_digest = hashlib.sha256(token.encode("utf-8")).digest()
        if (
            not separator
            or scheme.lower() != "bearer"
            or not token
            or not secrets.compare_digest(token_digest, self._credential_digest)
        ):
            await _json_error_response(
                send_without_storage,
                401,
                "unauthorized",
                "Bearer token 无效。",
                {"WWW-Authenticate": "Bearer"},
            )
            return

        decision = self._rate_limiter.consume(self._credential_key)
        if not decision.allowed:
            await _json_error_response(
                send_without_storage,
                429,
                "rate_limit_exceeded",
                "请求过于频繁，请稍后重试。",
                {"Retry-After": str(decision.retry_after_seconds)},
            )
            return

        await self._app(scope, receive, send_without_storage)


class RequestBodyLimitMiddleware:
    """只在配置上限内缓冲请求体，再交给 FastAPI。"""

    def __init__(
        self,
        app: ASGIApp,
        max_bytes: int,
        max_chunks: int = 4_096,
        receive_timeout_seconds: float = 15,
        protected_path: str = "/v1/journals/generate",
    ) -> None:
        self._app = app
        self._max_bytes = max_bytes
        self._max_chunks = max_chunks
        self._receive_timeout_seconds = receive_timeout_seconds
        self._protected_path = protected_path

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] != "http"
            or scope.get("method") != "POST"
            or scope.get("path") != self._protected_path
        ):
            await self._app(scope, receive, send)
            return

        headers = _headers(scope)
        content_length = headers.get("content-length")
        if content_length is not None:
            try:
                declared_length = int(content_length)
            except ValueError:
                await _error_response(send, 400, "invalid_content_length")
                return
            if declared_length < 0:
                await _error_response(send, 400, "invalid_content_length")
                return
            if declared_length > self._max_bytes:
                await _error_response(send, 413, "request_too_large")
                return

        body = bytearray()
        chunk_count = 0
        loop = asyncio.get_running_loop()
        receive_deadline = loop.time() + self._receive_timeout_seconds
        try:
            while True:
                remaining_seconds = receive_deadline - loop.time()
                if remaining_seconds <= 0:
                    raise asyncio.TimeoutError
                message = await asyncio.wait_for(receive(), timeout=remaining_seconds)
                if message["type"] == "http.disconnect":
                    return
                if message["type"] != "http.request":
                    continue
                chunk_count += 1
                if chunk_count > self._max_chunks:
                    await _error_response(send, 413, "request_too_fragmented")
                    return
                chunk = message.get("body", b"")
                if len(body) + len(chunk) > self._max_bytes:
                    await _error_response(send, 413, "request_too_large")
                    return
                body.extend(chunk)
                if not message.get("more_body", False):
                    break
        except asyncio.TimeoutError:
            await _error_response(send, 408, "request_timeout")
            return

        did_replay = False

        async def replay() -> Message:
            nonlocal did_replay
            if not did_replay:
                did_replay = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return {"type": "http.request", "body": b"", "more_body": False}

        await self._app(scope, replay, send)


def _headers(scope: Scope) -> Dict[str, str]:
    return {
        key.decode("latin-1").lower(): value.decode("latin-1")
        for key, value in scope.get("headers", [])
    }


async def _error_response(send: Send, status_code: int, code: str) -> None:
    messages = {
        400: "Content-Length 无效。",
        408: "接收请求体超时。",
        413: "请求体超过允许大小或分片数量。",
    }
    await _json_error_response(
        send,
        status_code,
        code,
        messages.get(status_code, "请求无效。"),
    )


async def _json_error_response(
    send: Send,
    status_code: int,
    code: str,
    message: str,
    headers: Optional[Dict[str, str]] = None,
) -> None:
    response = JSONResponse(
        status_code=status_code,
        headers=headers,
        content={
            "error": {
                "code": code,
                "message": message,
            }
        },
    )
    await response({"type": "http"}, _empty_receive, send)


async def _empty_receive() -> Message:
    return {"type": "http.request", "body": b"", "more_body": False}
