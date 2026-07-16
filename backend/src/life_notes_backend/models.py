from __future__ import annotations

from enum import Enum
from typing import Annotated, List
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class WritingStyle(str, Enum):
    natural = "natural"
    concise = "concise"
    delicate = "delicate"


TranscriptText = Annotated[str, Field(min_length=1, max_length=12_000)]


class JournalPhotoInput(StrictModel):
    annotation_text: str = Field(default="", max_length=4_000)
    voice_transcripts: List[TranscriptText] = Field(default_factory=list, max_length=1)

    @field_validator("annotation_text")
    @classmethod
    def validate_annotation_text(cls, value: str) -> str:
        return _validate_utf8_bytes(value, 4_000, "annotation_text")

    @field_validator("voice_transcripts")
    @classmethod
    def validate_voice_transcripts(cls, values: List[str]) -> List[str]:
        return [
            _validate_utf8_bytes(value, 12_000, "voice transcript")
            for value in values
        ]

    @model_validator(mode="after")
    def validate_readable_material(self) -> "JournalPhotoInput":
        if not self.annotation_text and not self.voice_transcripts:
            raise ValueError("photo must contain an annotation or voice transcript")
        return self


class JournalEntryInput(StrictModel):
    text: str = Field(default="", max_length=12_000)
    photos: List[JournalPhotoInput] = Field(default_factory=list, max_length=20)
    voice_transcripts: List[TranscriptText] = Field(default_factory=list, max_length=1)

    @field_validator("text")
    @classmethod
    def validate_text(cls, value: str) -> str:
        return _validate_utf8_bytes(value, 12_000, "entry text")

    @field_validator("voice_transcripts")
    @classmethod
    def validate_voice_transcripts(cls, values: List[str]) -> List[str]:
        return [
            _validate_utf8_bytes(value, 12_000, "voice transcript")
            for value in values
        ]

    @model_validator(mode="after")
    def validate_readable_material(self) -> "JournalEntryInput":
        if not self.text and not self.photos and not self.voice_transcripts:
            raise ValueError("entry must contain readable text material")
        return self


class JournalGenerationRequest(StrictModel):
    request_id: UUID
    style: WritingStyle
    entries: List[JournalEntryInput] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def validate_materials(self) -> "JournalGenerationRequest":
        has_readable_material = False
        for entry in self.entries:
            has_readable_material = has_readable_material or bool(entry.text)
            has_readable_material = has_readable_material or any(entry.voice_transcripts)
            for photo in entry.photos:
                has_readable_material = has_readable_material or bool(photo.annotation_text)
                has_readable_material = has_readable_material or any(
                    photo.voice_transcripts
                )

        if not has_readable_material:
            raise ValueError(
                "at least one text, photo annotation, or voice transcript is required"
            )
        return self


class GeneratedTextFields(StrictModel):
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=24_000)

    @field_validator("title")
    @classmethod
    def validate_title(cls, value: str) -> str:
        return _validate_generated_text(value, 120, "title")

    @field_validator("body")
    @classmethod
    def validate_body(cls, value: str) -> str:
        return _validate_generated_text(value, 24_000, "body")


class JournalGenerationResponse(GeneratedTextFields):
    request_id: UUID
    model: str = Field(
        min_length=1,
        max_length=200,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$",
    )
    generator_identifier: str = Field(
        min_length=27,
        max_length=226,
        pattern=r"^deepseek\.chat-completions\.[A-Za-z0-9][A-Za-z0-9._:/-]*$",
    )


class GeneratedJournalOutput(GeneratedTextFields):
    pass


def _validate_utf8_bytes(value: str, maximum_bytes: int, field_name: str) -> str:
    if len(value.encode("utf-8")) > maximum_bytes:
        raise ValueError(f"{field_name} exceeds its UTF-8 byte limit")
    return value


def _validate_generated_text(value: str, maximum_bytes: int, field_name: str) -> str:
    _validate_utf8_bytes(value, maximum_bytes, field_name)
    if any(ord(character) < 32 and character not in "\n\r\t" for character in value):
        raise ValueError(f"{field_name} contains unsupported control characters")
    return value
