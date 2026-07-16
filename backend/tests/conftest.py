from __future__ import annotations

import copy
from uuid import UUID

import pytest


@pytest.fixture
def valid_payload():
    payload = {
        "request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "style": "natural",
        "entries": [
            {
                "text": "今天完成了第一版联调。",
                "photos": [
                    {
                        "annotation_text": "傍晚的天空",
                        "voice_transcripts": ["回家的路上很安静。"],
                    }
                ],
                "voice_transcripts": ["今天的整体语音记录。"],
            }
        ],
    }
    return copy.deepcopy(payload)


@pytest.fixture
def request_id():
    return UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
