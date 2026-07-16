from __future__ import annotations

import asyncio

from life_notes_backend.middleware import RequestBodyLimitMiddleware


def test_streamed_body_without_content_length_is_still_limited():
    downstream_called = False

    async def downstream(_, __, ___):
        nonlocal downstream_called
        downstream_called = True

    middleware = RequestBodyLimitMiddleware(downstream, max_bytes=5)
    messages = iter(
        [
            {"type": "http.request", "body": b"123", "more_body": True},
            {"type": "http.request", "body": b"456", "more_body": False},
        ]
    )
    sent = []

    async def receive():
        return next(messages)

    async def send(message):
        sent.append(message)

    asyncio.run(
        middleware(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "method": "POST",
                "path": "/v1/journals/generate",
                "headers": [],
            },
            receive,
            send,
        )
    )

    assert not downstream_called
    start = next(message for message in sent if message["type"] == "http.response.start")
    assert start["status"] == 413


def test_body_at_limit_is_replayed_unchanged():
    received = []

    async def downstream(_, receive, __):
        received.append(await receive())
        received.append(await receive())

    middleware = RequestBodyLimitMiddleware(downstream, max_bytes=6)
    messages = iter(
        [
            {"type": "http.request", "body": b"123", "more_body": True},
            {"type": "http.request", "body": b"456", "more_body": False},
        ]
    )

    async def receive():
        return next(messages)

    async def send(_):
        return None

    asyncio.run(
        middleware(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "method": "POST",
                "path": "/v1/journals/generate",
                "headers": [],
            },
            receive,
            send,
        )
    )

    assert [message["body"] for message in received] == [b"123456", b""]


def test_excessive_empty_chunks_are_rejected_without_buffering_message_objects():
    downstream_called = False

    async def downstream(_, __, ___):
        nonlocal downstream_called
        downstream_called = True

    middleware = RequestBodyLimitMiddleware(
        downstream,
        max_bytes=128,
        max_chunks=4,
    )
    messages = iter(
        [
            {"type": "http.request", "body": b"", "more_body": True}
            for _ in range(5)
        ]
    )
    sent = []

    async def receive():
        return next(messages)

    async def send(message):
        sent.append(message)

    asyncio.run(
        middleware(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "method": "POST",
                "path": "/v1/journals/generate",
                "headers": [],
            },
            receive,
            send,
        )
    )

    assert not downstream_called
    start = next(message for message in sent if message["type"] == "http.response.start")
    assert start["status"] == 413


def test_public_health_path_does_not_read_request_body():
    downstream_called = False
    receive_called = False

    async def downstream(_, __, ___):
        nonlocal downstream_called
        downstream_called = True

    middleware = RequestBodyLimitMiddleware(downstream, max_bytes=128)

    async def receive():
        nonlocal receive_called
        receive_called = True
        return {"type": "http.request", "body": b"", "more_body": True}

    async def send(_):
        return None

    asyncio.run(
        middleware(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "method": "GET",
                "path": "/health",
                "headers": [],
            },
            receive,
            send,
        )
    )

    assert downstream_called
    assert not receive_called


def test_body_receive_timeout_returns_408_without_calling_downstream():
    downstream_called = False

    async def downstream(_, __, ___):
        nonlocal downstream_called
        downstream_called = True

    middleware = RequestBodyLimitMiddleware(
        downstream,
        max_bytes=128,
        receive_timeout_seconds=0.01,
    )
    sent = []

    async def receive():
        await asyncio.sleep(1)

    async def send(message):
        sent.append(message)

    asyncio.run(
        middleware(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "method": "POST",
                "path": "/v1/journals/generate",
                "headers": [],
            },
            receive,
            send,
        )
    )

    assert not downstream_called
    start = next(message for message in sent if message["type"] == "http.response.start")
    assert start["status"] == 408
