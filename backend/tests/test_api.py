from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from life_notes_backend.app import create_app
from life_notes_backend.config import Settings
from life_notes_backend.models import JournalGenerationRequest
from life_notes_backend.provider import (
    JournalProviderConfigurationError,
    JournalProviderRefusalError,
    JournalProviderResponseError,
    JournalProviderTimeoutError,
    JournalProviderUnavailableError,
    ProviderJournal,
)


TOKEN = "a-secure-test-token"


@dataclass
class FakeProvider:
    request: JournalGenerationRequest = None

    async def generate(self, request: JournalGenerationRequest) -> ProviderJournal:
        self.request = request
        return ProviderJournal(
            title="七月十五日",
            body="今天完成了第一版联调。",
            model="deepseek-v4-pro",
            generator_identifier="deepseek.chat-completions.deepseek-v4-pro",
        )


class LeakingErrorProvider:
    async def generate(self, _: JournalGenerationRequest) -> ProviderJournal:
        raise RuntimeError("PRIVATE JOURNAL BODY")


@dataclass
class TypedErrorProvider:
    error: Exception

    async def generate(self, _: JournalGenerationRequest) -> ProviderJournal:
        raise self.error


class InvalidProvenanceProvider:
    async def generate(self, _: JournalGenerationRequest) -> ProviderJournal:
        return ProviderJournal(
            title="标题",
            body="正文",
            model="deepseek-v4-pro",
            generator_identifier="deepseek.chat-completions.wrong-model",
        )


class MaximumEscapedOutputProvider:
    async def generate(self, _: JournalGenerationRequest) -> ProviderJournal:
        return ProviderJournal(
            title="边界",
            body='"' * 24_000,
            model="deepseek-v4-pro",
            generator_identifier="deepseek.chat-completions.deepseek-v4-pro",
        )


def make_client(
    provider,
    *,
    max_body_bytes=131_072,
    rate_limit=10,
):
    settings = Settings(
        bearer_token=TOKEN,
        deepseek_api_key="unused",
        max_request_body_bytes=max_body_bytes,
        rate_limit_requests_per_minute=rate_limit,
    )
    return TestClient(create_app(settings=settings, provider=provider))


def authorization():
    return {"Authorization": f"Bearer {TOKEN}"}


def test_health_is_public():
    with make_client(FakeProvider()) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert "cache-control" not in response.headers
    assert response.json() == {"status": "ok"}


def test_generate_requires_valid_bearer_token(valid_payload):
    with make_client(FakeProvider()) as client:
        missing = client.post("/v1/journals/generate", json=valid_payload)
        wrong = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers={"Authorization": "Bearer definitely-wrong"},
        )

    assert missing.status_code == 401
    assert missing.headers["www-authenticate"] == "Bearer"
    assert missing.headers["cache-control"] == "no-store"
    assert wrong.status_code == 401


def test_non_ascii_bearer_header_is_rejected_instead_of_crashing(valid_payload):
    with make_client(FakeProvider()) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=[(b"authorization", "Bearer 错误令牌".encode("utf-8"))],
        )

    assert response.status_code == 401


def test_authentication_and_rate_limit_run_before_json_parsing():
    with make_client(FakeProvider(), rate_limit=1) as client:
        missing = client.post(
            "/v1/journals/generate",
            content=b"{",
            headers={"Content-Type": "application/json"},
        )
        wrong = client.post(
            "/v1/journals/generate",
            content=b"{",
            headers={
                "Authorization": "Bearer definitely-wrong",
                "Content-Type": "application/json",
            },
        )
        invalid_but_authenticated = client.post(
            "/v1/journals/generate",
            content=b"{",
            headers={**authorization(), "Content-Type": "application/json"},
        )
        rate_limited = client.post(
            "/v1/journals/generate",
            content=b"{",
            headers={**authorization(), "Content-Type": "application/json"},
        )

    assert missing.status_code == 401
    assert wrong.status_code == 401
    assert invalid_but_authenticated.status_code == 422
    assert rate_limited.status_code == 429


def test_generate_returns_provider_result(valid_payload, request_id):
    provider = FakeProvider()
    with make_client(provider) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "request_id": str(request_id),
        "title": "七月十五日",
        "body": "今天完成了第一版联调。",
        "model": "deepseek-v4-pro",
        "generator_identifier": "deepseek.chat-completions.deepseek-v4-pro",
    }
    assert provider.request.request_id == request_id


def test_unknown_private_field_is_rejected_without_echo(valid_payload):
    secret = "PRIVATE/Photos/original.jpg"
    valid_payload["entries"][0]["photos"][0]["original_relative_path"] = secret
    with make_client(FakeProvider()) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == 422
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["error"]["code"] == "invalid_request"
    assert secret not in response.text


def test_request_body_size_limit(valid_payload):
    encoded = json.dumps(valid_payload).encode("utf-8")
    with make_client(FakeProvider(), max_body_bytes=1_024) as client:
        response = client.post(
            "/v1/journals/generate",
            content=encoded + b" " * 1_024,
            headers={**authorization(), "Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"


def test_application_rate_limit(valid_payload):
    with make_client(FakeProvider(), rate_limit=1) as client:
        first = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )
        second = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert first.status_code == 200
    assert second.status_code == 429
    assert int(second.headers["retry-after"]) >= 1


def test_provider_error_log_never_contains_exception_message(valid_payload, caplog):
    caplog.set_level(logging.ERROR, logger="life_notes_backend")
    with make_client(LeakingErrorProvider()) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == 503
    assert "PRIVATE JOURNAL BODY" not in caplog.text
    assert "今天完成了第一版联调" not in caplog.text


@pytest.mark.parametrize(
    "error,status_code,error_code",
    [
        (JournalProviderRefusalError(), 422, "generation_refused"),
        (JournalProviderResponseError(), 502, "invalid_provider_response"),
        (JournalProviderTimeoutError(), 504, "provider_timeout"),
        (
            JournalProviderConfigurationError(401),
            424,
            "provider_configuration_error",
        ),
        (JournalProviderUnavailableError(), 503, "provider_unavailable"),
    ],
)
def test_provider_errors_have_stable_api_codes(
    valid_payload,
    error,
    status_code,
    error_code,
):
    with make_client(TypedErrorProvider(error)) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == status_code
    assert response.json()["error"]["code"] == error_code


def test_api_rejects_mismatched_generator_identifier(valid_payload):
    with make_client(InvalidProvenanceProvider()) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "invalid_provider_response"


def test_maximum_valid_escaped_output_stays_inside_ios_response_budget(valid_payload):
    with make_client(MaximumEscapedOutputProvider()) as client:
        response = client.post(
            "/v1/journals/generate",
            json=valid_payload,
            headers=authorization(),
        )

    assert response.status_code == 200
    assert len(response.content) <= 65_536
    assert response.json()["body"] == '"' * 24_000
