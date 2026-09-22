import pytest
from pydantic import ValidationError


@pytest.mark.parametrize("query", ["Mom", "mom", " Mother ", "+15550109999", "Momm"])
def test_resolution(mock_contacts, query):
    result = mock_contacts.resolve(query)
    assert result.status == "resolved"
    assert result.contact.name == "Mom"


@pytest.mark.parametrize("query", ["John", "John Chon"])
def test_ambiguous(mock_contacts, query):
    result = mock_contacts.resolve(query)
    assert result.status == "ambiguous"
    assert len(result.candidates) == 2
    assert result.contact is None


@pytest.mark.parametrize("query", ["", "Zzzzzz", "+1555", "1234"])
def test_not_found(mock_contacts, query):
    assert mock_contacts.resolve(query).status == "not_found"


def test_raw_phone_group_template_and_summary(mock_contacts):
    assert mock_contacts.resolve("+442079460123").contact.phone == "+442079460123"
    assert [c.name for c in mock_contacts.get_group("FAMILY")] == ["Mom"]
    assert mock_contacts.get_template("Ma", "morning") == "Good morning!"
    assert mock_contacts.get_template("John", "morning") is None
    assert mock_contacts.get_summary() == {"count": 3, "groups": ["family", "work"]}


def test_reload_preserves_contacts_on_bad_edit(mock_contacts):
    mock_contacts.path.write_text('{"contacts": [{"name": "Broken"}]}')
    with pytest.raises(ValidationError):
        mock_contacts.reload()
    assert mock_contacts.resolve("Mom").status == "resolved"
    mock_contacts.path.write_text('{"contacts": []}')
    mock_contacts.reload()
    assert mock_contacts.get_summary()["count"] == 0
