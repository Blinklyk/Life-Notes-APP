import pytest

from life_notes_backend.config import ConfigurationError, Settings


def test_settings_default_to_deepseek_v4_pro():
    settings = Settings.from_env(
        {
            "LIFE_NOTES_BEARER_TOKEN": "a-secure-test-token",
            "DEEPSEEK_API_KEY": "test-key",
        }
    )

    assert settings.deepseek_model == "deepseek-v4-pro"
    assert settings.deepseek_base_url == "https://api.deepseek.com"
    assert settings.max_request_body_bytes == 131_072
    assert settings.deepseek_timeout_seconds == 30.0
    assert settings.deepseek_max_output_tokens == 2_000


def test_settings_require_secrets():
    with pytest.raises(ConfigurationError):
        Settings.from_env({})


@pytest.mark.parametrize(
    "name,value",
    [
        ("LIFE_NOTES_BEARER_TOKEN", "replace-with-at-least-16-random-characters"),
        ("LIFE_NOTES_BEARER_TOKEN", "0123456789abcdef-令牌"),
        ("LIFE_NOTES_BEARER_TOKEN", "a" * 513),
        ("DEEPSEEK_API_KEY", "replace-with-server-side-deepseek-api-key"),
        ("DEEPSEEK_API_KEY", "deepseek-密钥"),
        ("DEEPSEEK_API_KEY", "a" * 513),
    ],
)
def test_settings_reject_placeholders_non_ascii_and_oversized_secrets(name, value):
    environment = {
        "LIFE_NOTES_BEARER_TOKEN": "a-secure-test-token",
        "DEEPSEEK_API_KEY": "test-key",
    }
    environment[name] = value

    with pytest.raises(ConfigurationError):
        Settings.from_env(environment)


def test_settings_repr_does_not_reveal_secrets():
    settings = Settings(
        bearer_token="a-secure-test-token",
        deepseek_api_key="private-deepseek-key",
    )

    rendered = repr(settings)
    assert "a-secure-test-token" not in rendered
    assert "private-deepseek-key" not in rendered


def test_settings_reject_insecure_deepseek_base_url():
    with pytest.raises(ConfigurationError):
        Settings(
            bearer_token="a-secure-test-token",
            deepseek_api_key="private-key",
            deepseek_base_url="http://api.deepseek.com",
        )


def test_settings_accept_and_normalize_v1_api_root():
    settings = Settings(
        bearer_token="a-secure-test-token",
        deepseek_api_key="private-key",
        deepseek_base_url=" https://api.deepseek.com/v1/ ",
        deepseek_model=" deepseek-v4-pro ",
    )

    assert settings.deepseek_base_url == "https://api.deepseek.com/v1"
    assert settings.deepseek_model == "deepseek-v4-pro"


@pytest.mark.parametrize(
    "base_url",
    [
        "https://api.deepseek.com/v1?",
        "https://api.deepseek.com/v1#",
    ],
)
def test_settings_reject_even_empty_query_or_fragment_delimiters(base_url):
    with pytest.raises(ConfigurationError):
        Settings(
            bearer_token="a-secure-test-token",
            deepseek_api_key="private-key",
            deepseek_base_url=base_url,
        )


@pytest.mark.parametrize("timeout", [30.0001, 31, 35, 300])
def test_settings_keep_provider_timeout_inside_ios_request_window(timeout):
    with pytest.raises(ConfigurationError):
        Settings(
            bearer_token="a-secure-test-token",
            deepseek_api_key="private-key",
            deepseek_timeout_seconds=timeout,
        )
