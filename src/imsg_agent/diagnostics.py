"""Read-only prerequisites for history and drafting; never exercises delivery."""

from pathlib import Path

import httpx
import ollama

from imsg_agent.agent.backend import OllamaBackend
from imsg_agent.contacts.manager import ContactManager
from imsg_agent.reader import MessageReader, MessageReaderError


def check_readiness(config, contacts_path=None, messages_db=None):
    checks = []
    try:
        contacts = ContactManager(contacts_path or Path(config.data_dir) / "contacts.json")
        checks.append({"check": "contacts", "ok": True, "count": len(contacts.contacts)})
    except (OSError, ValueError):
        checks.append(
            {
                "check": "contacts",
                "ok": False,
                "detail": "Select a valid contacts JSON with --contacts.",
            }
        )
    try:
        MessageReader(messages_db).check_schema()
        checks.append({"check": "messages_schema", "ok": True})
    except MessageReaderError as exc:
        checks.append({"check": "messages_schema", "ok": False, "detail": str(exc)})
    try:
        backend = OllamaBackend(config.ollama_model, config.ollama_host, timeout=5)
        models = backend.client.list().models
        # Ollama reports the explicit default tag even if configuration omits it.
        name = config.ollama_model
        canonical = name if ":" in name.rsplit("/", 1)[-1] else name + ":latest"
        present = any(m.model == canonical for m in models)
        checks.append({"check": "ollama", "ok": True})
        checks.append(
            {
                "check": "model",
                "ok": present,
                "model": name,
                "detail": "Installed; inference not yet tested."
                if present
                else "Download the configured model with Ollama before testing replies.",
            }
        )
    except (ollama.ResponseError, httpx.HTTPError, ConnectionError, OSError, ValueError):
        checks.append(
            {
                "check": "ollama",
                "ok": False,
                "detail": "Check that Ollama is running and ollama_host is a reachable loopback URL.",
            }
        )
    return {
        "ready": all(c["ok"] for c in checks),
        "checks": checks,
        "scope": "Prerequisites only: no conversation rows, inference, sends, or daemon changes.",
    }
