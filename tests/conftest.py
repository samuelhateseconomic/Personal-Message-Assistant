"""Foundation fixtures use temporary files and never invoke Messages.app."""

import json
from unittest.mock import Mock

import pytest

from imsg_agent.contacts.manager import ContactManager
from imsg_agent.store import Store


@pytest.fixture
def tmp_db(tmp_path):
    store = Store(tmp_path / "test.db")
    yield store
    store.close()


@pytest.fixture
def mock_contacts(tmp_path):
    path = tmp_path / "contacts.json"
    path.write_text(
        json.dumps(
            {
                "contacts": [
                    {
                        "name": "Mom",
                        "phone": "+15550109999",
                        "aliases": ["Mother", "Ma"],
                        "group": ["family"],
                        "templates": {"morning": "Good morning!"},
                    },
                    {
                        "name": "John Chen",
                        "phone": "+15550108888",
                        "aliases": ["John"],
                        "group": ["work"],
                    },
                    {"name": "John Chan", "phone": "+15550107777", "aliases": ["John"]},
                ]
            }
        )
    )
    return ContactManager(path)


@pytest.fixture
def mock_backend():
    return Mock()


@pytest.fixture
def mock_messenger():
    return Mock()
