import pytest
from pydantic import ValidationError

from life_notes_backend.models import GeneratedJournalOutput, JournalGenerationRequest


@pytest.mark.parametrize(
    "field,value",
    [
        ("original_relative_path", "Photos/private.jpg"),
        ("image_base64", "cHJpdmF0ZQ=="),
        ("image_bytes", [1, 2, 3]),
    ],
)
def test_photo_rejects_paths_and_binary_fields(valid_payload, field, value):
    valid_payload["entries"][0]["photos"][0][field] = value

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_voice_rejects_audio_path(valid_payload):
    valid_payload["entries"][0]["audio_path"] = "Audio/a.m4a"

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_requires_readable_material(valid_payload):
    entry = valid_payload["entries"][0]
    entry["text"] = "  "
    entry["photos"][0]["annotation_text"] = ""
    entry["photos"][0]["voice_transcripts"] = ["\n"]
    entry["voice_transcripts"] = ["  "]

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_rejects_empty_entry_and_photo_even_when_another_entry_is_readable(valid_payload):
    valid_payload["entries"].append(
        {
            "text": "",
            "photos": [{"annotation_text": "", "voice_transcripts": []}],
            "voice_transcripts": [],
        }
    )

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


@pytest.mark.parametrize("location", ["entry", "photo"])
def test_rejects_empty_transcript_items(valid_payload, location):
    if location == "entry":
        valid_payload["entries"][0]["voice_transcripts"] = [" \n "]
    else:
        valid_payload["entries"][0]["photos"][0]["voice_transcripts"] = ["\t"]

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


@pytest.mark.parametrize(
    "field,value",
    [
        ("day_key", 20260715),
        ("source_fingerprint", "a" * 64),
        ("id", "11111111-1111-4111-8111-111111111111"),
    ],
)
def test_rejects_linkable_request_metadata(valid_payload, field, value):
    valid_payload[field] = value

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_rejects_stable_photo_identifier(valid_payload):
    valid_payload["entries"][0]["photos"][0]["id"] = (
        "22222222-2222-4222-8222-222222222222"
    )

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_rejects_stable_voice_target_identifier(valid_payload):
    valid_payload["entries"][0]["photos"][0]["target_photo_id"] = (
        "99999999-9999-4999-8999-999999999999"
    )

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


@pytest.mark.parametrize("location", ["entry", "photo"])
def test_limits_each_voice_transcript_collection_to_one(valid_payload, location):
    if location == "entry":
        valid_payload["entries"][0]["voice_transcripts"] = ["一", "二"]
    else:
        valid_payload["entries"][0]["photos"][0]["voice_transcripts"] = [
            "一",
            "二",
        ]

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


@pytest.mark.parametrize(
    "location,value",
    [
        ("entry", "👨‍👩‍👧‍👦" * 500),
        ("photo", "e\u0301" * 1_334),
        ("entry_voice", "中" * 4_001),
        ("photo_voice", "中" * 4_001),
    ],
)
def test_text_limits_use_utf8_bytes_instead_of_visual_character_count(
    valid_payload,
    location,
    value,
):
    entry = valid_payload["entries"][0]
    if location == "entry":
        entry["text"] = value
    elif location == "photo":
        entry["photos"][0]["annotation_text"] = value
    elif location == "entry_voice":
        entry["voice_transcripts"] = [value]
    else:
        entry["photos"][0]["voice_transcripts"] = [value]

    with pytest.raises(ValidationError):
        JournalGenerationRequest.model_validate(valid_payload)


def test_generated_output_uses_utf8_byte_limits_and_rejects_binary_controls():
    with pytest.raises(ValidationError):
        GeneratedJournalOutput(title="中" * 41, body="正文")
    with pytest.raises(ValidationError):
        GeneratedJournalOutput(title="标题", body="中" * 8_001)
    with pytest.raises(ValidationError):
        GeneratedJournalOutput(title="标题", body="正文\u0000隐藏")
