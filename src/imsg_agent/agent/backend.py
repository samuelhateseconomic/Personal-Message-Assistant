"""Local Ollama adapter using structured JSON, including models without native tools."""

import ipaddress
import json
from urllib.parse import urlparse

import httpx
import ollama


class BackendUnavailable(RuntimeError):
    pass


class OllamaBackend:
    def __init__(self, model="gemma3:12b", host="http://localhost:11434", client=None):
        parsed = urlparse(host)
        local = parsed.hostname == "localhost"
        try:
            local = local or ipaddress.ip_address(parsed.hostname or "").is_loopback
        except ValueError:
            pass
        if (
            parsed.scheme not in ("http", "https")
            or not local
            or parsed.username
            or parsed.password
        ):
            raise ValueError("Ollama host must be a loopback address for local contact processing")
        self.model = model
        self.client = client or ollama.Client(host=host, timeout=60, trust_env=False)

    def is_available(self):
        try:
            self.client.list()
            return True
        except (ollama.ResponseError, httpx.HTTPError, ConnectionError, OSError):
            return False

    def ensure_model_pulled(self):
        models = self.client.list().models
        if not any(m.model == self.model for m in models):
            self.client.pull(self.model)

    def chat(self, messages, tools):
        schema = {
            "type": "object",
            "properties": {
                "content": {"type": "string"},
                "tool_calls": {
                    "type": "array",
                    "maxItems": 1,
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {
                                "type": "string",
                                "enum": [t["function"]["name"] for t in tools],
                            },
                            "arguments": {"type": "object"},
                        },
                        "required": ["name", "arguments"],
                    },
                },
            },
            "required": ["content", "tool_calls"],
        }
        request = list(messages)
        request[0] = {
            **request[0],
            "content": request[0]["content"]
            + "\nReturn JSON with content and tool_calls. Use at most one tool per response. "
            "Available tool schemas: " + json.dumps(tools),
        }
        try:
            result = self.client.chat(
                model=self.model, messages=request, format=schema, options={"temperature": 0}
            )
            response = json.loads(result.message.content or "{}")
            if not isinstance(response, dict) or not isinstance(
                response.get("tool_calls", []), list
            ):
                raise TypeError("Malformed model response")
            return response
        except (
            ollama.ResponseError,
            httpx.HTTPError,
            ConnectionError,
            OSError,
            ValueError,
            TypeError,
        ) as exc:
            raise BackendUnavailable("Local model unavailable or returned invalid JSON") from exc
