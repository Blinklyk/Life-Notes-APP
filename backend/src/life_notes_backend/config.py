from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Mapping, Optional
from urllib.parse import urlsplit


class ConfigurationError(ValueError):
    """运行时配置缺失或无效。"""


@dataclass(frozen=True)
class Settings:
    bearer_token: str = field(repr=False)
    deepseek_api_key: str = field(repr=False)
    deepseek_base_url: str = "https://api.deepseek.com"
    deepseek_model: str = "deepseek-v4-pro"
    max_request_body_bytes: int = 131_072
    rate_limit_requests_per_minute: int = 10
    deepseek_timeout_seconds: float = 30.0
    deepseek_max_output_tokens: int = 2_000

    def __post_init__(self) -> None:
        token = self.bearer_token.strip()
        if (
            not 16 <= len(token) <= 512
            or not _contains_only_visible_ascii(token)
            or _looks_like_placeholder(token)
        ):
            raise ConfigurationError(
                "LIFE_NOTES_BEARER_TOKEN must contain 16 to 512 visible ASCII "
                "characters and cannot be a placeholder"
            )
        api_key = self.deepseek_api_key.strip()
        if (
            not 1 <= len(api_key) <= 512
            or not _contains_only_visible_ascii(api_key)
            or _looks_like_placeholder(api_key)
        ):
            raise ConfigurationError(
                "DEEPSEEK_API_KEY must contain 1 to 512 visible ASCII characters "
                "and cannot be a placeholder"
            )
        if not 1_024 <= self.max_request_body_bytes <= 1_048_576:
            raise ConfigurationError(
                "MAX_REQUEST_BODY_BYTES must be between 1024 and 1048576"
            )
        if not 1 <= self.rate_limit_requests_per_minute <= 10_000:
            raise ConfigurationError(
                "RATE_LIMIT_REQUESTS_PER_MINUTE must be between 1 and 10000"
            )
        if not 1 <= self.deepseek_timeout_seconds <= 30:
            raise ConfigurationError("DEEPSEEK_TIMEOUT_SECONDS must be between 1 and 30")
        if not 128 <= self.deepseek_max_output_tokens <= 16_384:
            raise ConfigurationError(
                "DEEPSEEK_MAX_OUTPUT_TOKENS must be between 128 and 16384"
            )
        model = self.deepseek_model.strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}", model):
            raise ConfigurationError("DEEPSEEK_MODEL contains unsupported characters")
        base_url = self.deepseek_base_url.strip().rstrip("/")
        _validate_deepseek_base_url(base_url)
        object.__setattr__(self, "bearer_token", token)
        object.__setattr__(self, "deepseek_api_key", api_key)
        object.__setattr__(self, "deepseek_base_url", base_url)
        object.__setattr__(self, "deepseek_model", model)

    def require_deepseek_api_key(self) -> str:
        key = self.deepseek_api_key.strip()
        if not key:
            raise ConfigurationError("DEEPSEEK_API_KEY is required")
        return key

    @classmethod
    def from_env(cls, environ: Optional[Mapping[str, str]] = None) -> "Settings":
        values = os.environ if environ is None else environ
        return cls(
            bearer_token=_required(values, "LIFE_NOTES_BEARER_TOKEN"),
            deepseek_api_key=_required(values, "DEEPSEEK_API_KEY"),
            deepseek_base_url=values.get(
                "DEEPSEEK_BASE_URL",
                "https://api.deepseek.com",
            ),
            deepseek_model=values.get("DEEPSEEK_MODEL", "deepseek-v4-pro"),
            max_request_body_bytes=_integer(
                values,
                "MAX_REQUEST_BODY_BYTES",
                default=131_072,
            ),
            rate_limit_requests_per_minute=_integer(
                values,
                "RATE_LIMIT_REQUESTS_PER_MINUTE",
                default=10,
            ),
            deepseek_timeout_seconds=_floating_point(
                values,
                "DEEPSEEK_TIMEOUT_SECONDS",
                default=30.0,
            ),
            deepseek_max_output_tokens=_integer(
                values,
                "DEEPSEEK_MAX_OUTPUT_TOKENS",
                default=2_000,
            ),
        )


def _required(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value:
        raise ConfigurationError(f"{name} is required")
    return value


def _contains_only_visible_ascii(value: str) -> bool:
    return all(33 <= ord(character) <= 126 for character in value)


def _looks_like_placeholder(value: str) -> bool:
    normalized = value.lower()
    return normalized.startswith("replace-with-") or normalized in {
        "changeme",
        "change-me",
    }


def _integer(values: Mapping[str, str], name: str, default: int) -> int:
    raw_value = values.get(name)
    if raw_value is None:
        return default
    try:
        return int(raw_value)
    except ValueError as error:
        raise ConfigurationError(f"{name} must be an integer") from error


def _floating_point(values: Mapping[str, str], name: str, default: float) -> float:
    raw_value = values.get(name)
    if raw_value is None:
        return default
    try:
        return float(raw_value)
    except ValueError as error:
        raise ConfigurationError(f"{name} must be a number") from error


def _validate_deepseek_base_url(value: str) -> None:
    if "?" in value or "#" in value:
        raise ConfigurationError(
            "DEEPSEEK_BASE_URL must not contain query or fragment delimiters"
        )
    parsed = urlsplit(value.strip())
    try:
        parsed.port
    except ValueError as error:
        raise ConfigurationError("DEEPSEEK_BASE_URL contains an invalid port") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or any(character.isspace() for character in value)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigurationError(
            "DEEPSEEK_BASE_URL must be an HTTPS API root without credentials, query, or fragment"
        )
