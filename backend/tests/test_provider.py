from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager

import httpx
import pytest

from life_notes_backend.models import JournalGenerationRequest
from life_notes_backend.provider import (
    DeepSeekJournalProvider,
    JournalProviderConfigurationError,
    JournalProviderRefusalError,
    JournalProviderResponseError,
    JournalProviderTimeoutError,
    JournalProviderUnavailableError,
)


class NeverCompletesClient:
    @asynccontextmanager
    async def stream(self, *_args, **_kwargs):
        await asyncio.sleep(1)
        yield


class CancelledClient:
    @asynccontextmanager
    async def stream(self, *_args, **_kwargs):
        raise asyncio.CancelledError
        yield


class TrackingByteStream(httpx.AsyncByteStream):
    def __init__(self, chunks):
        self.chunks = chunks
        self.emitted_count = 0
        self.was_closed = False

    async def __aiter__(self):
        for chunk in self.chunks:
            self.emitted_count += 1
            yield chunk

    async def aclose(self):
        self.was_closed = True


def test_chat_completions_uses_json_mode_without_media(valid_payload):
    captured = {}

    def handle_request(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["authorization"] = request.headers["authorization"]
        captured["cache_control"] = request.headers["cache-control"]
        captured["accept_encoding"] = request.headers["accept-encoding"]
        captured["payload"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "model": "deepseek-v4-pro-202607",
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {
                            "role": "assistant",
                            "content": json.dumps(
                                {"title": "平静的一天", "body": "今天完成了联调。"},
                                ensure_ascii=False,
                            ),
                        },
                    }
                ],
            },
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="deepseek-test-key",
                base_url="https://api.deepseek.com/v1/",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            return await provider.generate(
                JournalGenerationRequest.model_validate(valid_payload)
            )

    result = asyncio.run(run_scenario())

    assert captured["url"] == "https://api.deepseek.com/v1/chat/completions"
    assert captured["authorization"] == "Bearer deepseek-test-key"
    assert captured["cache_control"] == "no-store"
    assert captured["accept_encoding"] == "identity"
    payload = captured["payload"]
    assert payload["model"] == "deepseek-v4-pro"
    assert payload["response_format"] == {"type": "json_object"}
    assert payload["stream"] is False
    assert payload["max_tokens"] == 2_000
    serialized_payload = json.dumps(payload, ensure_ascii=False)
    assert "original_relative_path" not in serialized_payload
    assert "image_base64" not in serialized_payload
    provider_materials = payload["messages"][1]["content"]
    assert "request_id" not in provider_materials
    assert "day_key" not in provider_materials
    assert "source_fingerprint" not in provider_materials
    assert "11111111-1111-4111-8111-111111111111" not in provider_materials
    assert "22222222-2222-4222-8222-222222222222" not in provider_materials
    assert "33333333-3333-4333-8333-333333333333" not in provider_materials
    assert result.model == "deepseek-v4-pro-202607"
    assert (
        result.generator_identifier
        == "deepseek.chat-completions.deepseek-v4-pro-202607"
    )


def test_provider_restricts_sensitive_dependency_logging():
    httpx_logger = logging.getLogger("httpx")
    previous_level = httpx_logger.level
    httpx_logger.setLevel(logging.DEBUG)
    try:
        DeepSeekJournalProvider(
            api_key="unused",
            base_url="https://api.deepseek.com",
            model="deepseek-v4-pro",
            timeout_seconds=1,
            client=NeverCompletesClient(),
        )
        assert httpx_logger.level >= logging.WARNING
    finally:
        httpx_logger.setLevel(previous_level)


def test_provider_uses_configured_model_when_response_omits_it(valid_payload):
    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {
                            "content": '{"title":"今天","body":"一段正文。"}'
                        },
                    }
                ]
            },
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            return await provider.generate(
                JournalGenerationRequest.model_validate(valid_payload)
            )

    result = asyncio.run(run_scenario())

    assert result.model == "deepseek-v4-pro"
    assert result.generator_identifier == "deepseek.chat-completions.deepseek-v4-pro"


@pytest.mark.parametrize(
    "finish_reason,refusal",
    [("content_filter", None), ("stop", "request refused")],
)
def test_provider_handles_refusal(valid_payload, finish_reason, refusal):
    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": finish_reason,
                        "message": {"content": None, "refusal": refusal},
                    }
                ]
            },
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderRefusalError):
        asyncio.run(run_scenario())


@pytest.mark.parametrize(
    "finish_reason,content",
    [
        ("length", '{"title":"半截"'),
        ("stop", "not-json"),
        ("stop", ""),
        ("stop", '{"title":"标题","body":"正文","extra":true}'),
    ],
)
def test_provider_rejects_incomplete_or_invalid_output(
    valid_payload,
    finish_reason,
    content,
):
    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": finish_reason,
                        "message": {"content": content},
                    }
                ]
            },
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderResponseError):
        asyncio.run(run_scenario())


def test_provider_enforces_application_timeout(valid_payload):
    provider = DeepSeekJournalProvider(
        api_key="unused",
        base_url="https://api.deepseek.com",
        model="deepseek-v4-pro",
        timeout_seconds=0.01,
        client=NeverCompletesClient(),
    )

    with pytest.raises(JournalProviderTimeoutError):
        asyncio.run(
            provider.generate(JournalGenerationRequest.model_validate(valid_payload))
        )


def test_provider_preserves_task_cancellation(valid_payload):
    provider = DeepSeekJournalProvider(
        api_key="unused",
        base_url="https://api.deepseek.com",
        model="deepseek-v4-pro",
        timeout_seconds=1,
        client=CancelledClient(),
    )

    with pytest.raises(asyncio.CancelledError):
        asyncio.run(
            provider.generate(JournalGenerationRequest.model_validate(valid_payload))
        )


def test_provider_stops_streaming_as_soon_as_response_exceeds_limit(valid_payload):
    stream = TrackingByteStream([b"1234", b"56", b"must-not-be-read"])

    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, stream=stream)

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                max_response_bytes=5,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderResponseError):
        asyncio.run(run_scenario())
    assert stream.emitted_count == 2
    assert stream.was_closed


def test_provider_rejects_compressed_response_before_reading_stream(valid_payload):
    stream = TrackingByteStream([b"compressed-data-must-not-be-read"])

    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"Content-Encoding": "gzip"},
            stream=stream,
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderResponseError):
        asyncio.run(run_scenario())
    assert stream.emitted_count == 0
    assert stream.was_closed


@pytest.mark.parametrize("status_code", [300, 400, 401, 403, 404, 422])
def test_provider_maps_permanent_status_to_configuration_error_without_response(
    valid_payload,
    status_code,
):
    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status_code,
            json={"error": {"message": "PRIVATE DETAIL"}},
        )

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderConfigurationError) as captured:
        asyncio.run(run_scenario())
    assert captured.value.status_code == status_code
    assert "PRIVATE DETAIL" not in str(captured.value)


@pytest.mark.parametrize("status_code", [408, 429, 500, 503])
def test_provider_maps_temporary_status_to_unavailable(valid_payload, status_code):
    def handle_request(_: httpx.Request) -> httpx.Response:
        return httpx.Response(status_code)

    async def run_scenario():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle_request)) as client:
            provider = DeepSeekJournalProvider(
                api_key="unused",
                base_url="https://api.deepseek.com",
                model="deepseek-v4-pro",
                timeout_seconds=1,
                client=client,
            )
            await provider.generate(JournalGenerationRequest.model_validate(valid_payload))

    with pytest.raises(JournalProviderUnavailableError):
        asyncio.run(run_scenario())
