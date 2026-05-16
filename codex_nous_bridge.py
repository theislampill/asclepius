#!/usr/bin/env python3
"""Local Responses API bridge for Codex -> Hermes Nous proxy.

The default Codex app stays untouched. This bridge gives an isolated Codex
profile a Responses-compatible endpoint while Hermes' built-in proxy handles
Nous Portal auth and forwards to Nous' Chat Completions API.
"""

from __future__ import annotations

import json
import os
import time
import uuid
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ROOT = os.path.dirname(os.path.abspath(__file__))
HOST = os.environ.get("CODEX_NOUS_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_NOUS_BRIDGE_PORT", "8655"))
UPSTREAM_BASE = os.environ.get("CODEX_NOUS_PROXY_BASE", "http://127.0.0.1:8645/v1").rstrip("/")
NOUS_DIRECT_BASE = os.environ.get("CODEX_NOUS_DIRECT_BASE", "https://inference-api.nousresearch.com/v1").rstrip("/")
OPENROUTER_BASE = os.environ.get("CODEX_OPENROUTER_BASE", "https://openrouter.ai/api/v1").rstrip("/")
SECRETS_PATH = os.environ.get("CODEX_CLOUD_SECRETS_PATH", os.path.join(ROOT, "cloud-secrets.json"))
CATALOG_PATH = os.environ.get("CODEX_CLOUD_MODELS_PATH", os.path.join(ROOT, "cloud-models.json"))
DEFAULT_MODEL = os.environ.get("CODEX_NOUS_DEFAULT_MODEL", "nous/deepseek/deepseek-v4-flash")

RESPONSES: dict[str, dict[str, Any]] = {}


class BridgeError(Exception):
    def __init__(self, message: str, status: int = 502, typ: str = "bridge_error") -> None:
        super().__init__(message)
        self.status = status
        self.typ = typ


def now() -> int:
    return int(time.time())


def response_id() -> str:
    return f"resp_{uuid.uuid4().hex}"


def item_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:24]}"


def load_secrets() -> dict[str, Any]:
    try:
        with open(SECRETS_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception:
        return {}


def openrouter_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return key
    secret = load_secrets().get("openrouter_api_key", "")
    return str(secret or "").strip()


def nous_key() -> str:
    key = os.environ.get("NOUS_API_KEY", "").strip()
    if key:
        return key
    secret = load_secrets().get("nous_api_key", "")
    return str(secret or "").strip()


def decode_route_model_id(value: str) -> str:
    return value.replace("__colon__", ":")


def parse_model_route(model: str) -> dict[str, str]:
    requested = (model or DEFAULT_MODEL).strip()
    if requested.startswith("openrouter/"):
        upstream_model = decode_route_model_id(requested.split("/", 1)[1].strip())
        if not upstream_model:
            raise BridgeError("OpenRouter model route is missing its model id.", 400, "invalid_model")
        return {"provider": "openrouter", "upstream_model": upstream_model, "requested_model": requested}
    if requested.startswith("nous/"):
        upstream_model = decode_route_model_id(requested.split("/", 1)[1].strip())
        if not upstream_model:
            raise BridgeError("Nous model route is missing its model id.", 400, "invalid_model")
        return {"provider": "nous", "upstream_model": upstream_model, "requested_model": requested}
    if requested.startswith("openrouter:"):
        upstream_model = requested.split(":", 1)[1].strip()
        if not upstream_model:
            raise BridgeError("OpenRouter model route is missing its model id.", 400, "invalid_model")
        return {"provider": "openrouter", "upstream_model": upstream_model, "requested_model": requested}
    if requested.startswith("nous:"):
        upstream_model = requested.split(":", 1)[1].strip()
        if not upstream_model:
            raise BridgeError("Nous model route is missing its model id.", 400, "invalid_model")
        return {"provider": "nous", "upstream_model": upstream_model, "requested_model": requested}
    return {"provider": "nous", "upstream_model": requested, "requested_model": f"nous/{requested}"}


def flatten_content(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for part in value:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                typ = part.get("type")
                if typ in {"input_text", "output_text", "text"}:
                    parts.append(str(part.get("text", "")))
                elif "content" in part:
                    parts.append(flatten_content(part.get("content")))
        return "\n".join(p for p in parts if p)
    if isinstance(value, dict):
        if "text" in value:
            return str(value.get("text") or "")
        if "content" in value:
            return flatten_content(value.get("content"))
        if "output" in value:
            return flatten_content(value.get("output"))
    return str(value)


def responses_input_to_chat(body: dict[str, Any]) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    prev = body.get("previous_response_id")
    if prev and prev in RESPONSES:
        messages.extend(RESPONSES[prev].get("chat_history", []))

    instructions = flatten_content(body.get("instructions"))
    if instructions:
        messages.append({"role": "system", "content": instructions})

    incoming = body.get("input")
    if isinstance(incoming, str):
        if incoming.strip():
            messages.append({"role": "user", "content": incoming})
        return messages

    if isinstance(incoming, dict):
        incoming = [incoming]
    if not isinstance(incoming, list):
        return messages

    for entry in incoming:
        if isinstance(entry, str):
            messages.append({"role": "user", "content": entry})
            continue
        if not isinstance(entry, dict):
            continue
        typ = entry.get("type")
        if typ == "function_call_output":
            call_id = entry.get("call_id") or entry.get("id") or ""
            messages.append({
                "role": "tool",
                "tool_call_id": call_id,
                "content": flatten_content(entry.get("output")),
            })
            continue
        role = entry.get("role")
        if typ == "message" or role in {"system", "user", "assistant"}:
            messages.append({
                "role": role if role in {"system", "user", "assistant"} else "user",
                "content": flatten_content(entry.get("content")),
            })
    return messages


def responses_tools_to_chat(tools: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not isinstance(tools, list):
        return out
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        if tool.get("type") != "function":
            continue
        if isinstance(tool.get("function"), dict):
            out.append({"type": "function", "function": tool["function"]})
            continue
        name = tool.get("name")
        if not name:
            continue
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description", ""),
                "parameters": tool.get("parameters") or tool.get("input_schema") or {"type": "object"},
            },
        })
    return out


def chat_tool_call_to_response(call: dict[str, Any]) -> dict[str, Any]:
    fn = call.get("function") or {}
    return {
        "id": item_id("fc"),
        "type": "function_call",
        "status": "completed",
        "name": fn.get("name") or call.get("name") or "",
        "call_id": call.get("id") or item_id("call"),
        "arguments": fn.get("arguments") or "{}",
    }


def build_message_item(text: str, status: str = "completed", msg_id: str | None = None) -> dict[str, Any]:
    return {
        "id": msg_id or item_id("msg"),
        "type": "message",
        "status": status,
        "role": "assistant",
        "content": [{"type": "output_text", "text": text}],
    }


def usage_from_chat(usage: dict[str, Any] | None) -> dict[str, int]:
    usage = usage or {}
    input_tokens = int(usage.get("prompt_tokens") or usage.get("input_tokens") or 0)
    output_tokens = int(usage.get("completion_tokens") or usage.get("output_tokens") or 0)
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": int(usage.get("total_tokens") or input_tokens + output_tokens),
    }


def upstream_request(payload: dict[str, Any], stream: bool):
    provider = payload.get("_codex_provider", "nous")
    clean_payload = {key: value for key, value in payload.items() if not key.startswith("_codex_")}
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if stream else "application/json",
    }
    if provider == "openrouter":
        key = openrouter_key()
        if not key:
            raise BridgeError(
                "OpenRouter API key is missing. Set it from the Cloud-Codex picker or OPENROUTER_API_KEY.",
                401,
                "missing_api_key",
            )
        url = f"{OPENROUTER_BASE}/chat/completions"
        headers["Authorization"] = f"Bearer {key}"
        headers["HTTP-Referer"] = "http://127.0.0.1:8655"
        headers["X-Title"] = "Cloud-Codex"
    else:
        key = nous_key()
        if key:
            url = f"{NOUS_DIRECT_BASE}/chat/completions"
            headers["Authorization"] = f"Bearer {key}"
        else:
            url = f"{UPSTREAM_BASE}/chat/completions"
            headers["Authorization"] = "Bearer local-codex-nous-bridge"

    data = json.dumps(clean_payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST", headers=headers)
    return urllib.request.urlopen(request, timeout=300)


def write_json(handler: BaseHTTPRequestHandler, data: Any, status: int = 200) -> None:
    body = json.dumps(data).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def sse_payload(event: str, data: dict[str, Any], seq: int) -> bytes:
    data.setdefault("sequence_number", seq)
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode("utf-8")


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "CodexNousBridge/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in {"/health", "/v1/health"}:
            write_json(self, {
                "status": "ok",
                "bridge": "codex-cloud",
                "nous_upstream": UPSTREAM_BASE,
                "nous_direct_upstream": NOUS_DIRECT_BASE,
                "openrouter_upstream": OPENROUTER_BASE,
                "default_model": DEFAULT_MODEL,
                "providers": {
                    "nous": {
                        "ready": True,
                        "api_key_present": bool(nous_key()),
                        "credential": "Hermes OAuth via proxy; optional direct NOUS_API_KEY/cloud secret",
                        "active_auth": "direct_api_key" if nous_key() else "hermes_oauth_proxy",
                    },
                    "openrouter": {"api_key_present": bool(openrouter_key()), "credential": "OpenRouter API key"},
                },
            })
            return
        if self.path == "/v1/models":
            try:
                if os.path.exists(CATALOG_PATH):
                    with open(CATALOG_PATH, "r", encoding="utf-8") as handle:
                        catalog = json.load(handle)
                    body = {
                        "object": "list",
                        "data": [
                            {
                                "id": model.get("slug"),
                                "object": "model",
                                "owned_by": model.get("provider_display") or model.get("provider"),
                                "display": model.get("display"),
                            }
                            for model in catalog.get("models", [])
                            if isinstance(model, dict) and model.get("slug")
                        ],
                    }
                else:
                    req = urllib.request.Request(
                        f"{UPSTREAM_BASE}/models",
                        headers={"Authorization": "Bearer local-codex-nous-bridge"},
                    )
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        body = json.loads(resp.read().decode("utf-8"))
                write_json(self, body)
            except Exception as exc:  # noqa: BLE001
                write_json(self, {"error": {"message": str(exc), "type": "upstream_error"}}, 502)
            return
        if self.path.startswith("/v1/responses/"):
            rid = self.path.rsplit("/", 1)[-1]
            stored = RESPONSES.get(rid)
            if not stored:
                write_json(self, {"error": {"message": f"response not found: {rid}"}}, 404)
                return
            write_json(self, stored["response"])
            return
        write_json(self, {"error": {"message": "not found"}}, HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:  # noqa: N802
        if self.path.startswith("/v1/responses/"):
            rid = self.path.rsplit("/", 1)[-1]
            RESPONSES.pop(rid, None)
            write_json(self, {"id": rid, "deleted": True, "object": "response.deleted"})
            return
        write_json(self, {"error": {"message": "not found"}}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/responses":
            write_json(self, {"error": {"message": "not found"}}, HTTPStatus.NOT_FOUND)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except json.JSONDecodeError:
            write_json(self, {"error": {"message": "invalid JSON"}}, HTTPStatus.BAD_REQUEST)
            return

        stream = bool(body.get("stream"))
        try:
            route = parse_model_route(body.get("model") or DEFAULT_MODEL)
        except BridgeError as exc:
            write_json(self, {"error": {"message": str(exc), "type": exc.typ}}, exc.status)
            return
        messages = responses_input_to_chat(body)
        chat_payload: dict[str, Any] = {
            "model": route["upstream_model"],
            "messages": messages or [{"role": "user", "content": ""}],
            "stream": stream,
            "_codex_provider": route["provider"],
            "_codex_requested_model": route["requested_model"],
        }
        tools = responses_tools_to_chat(body.get("tools"))
        if tools:
            chat_payload["tools"] = tools
            if body.get("tool_choice"):
                chat_payload["tool_choice"] = body["tool_choice"]

        if stream:
            self.handle_streaming(body, chat_payload, messages)
        else:
            self.handle_non_streaming(body, chat_payload, messages)

    def handle_non_streaming(
        self,
        body: dict[str, Any],
        chat_payload: dict[str, Any],
        messages: list[dict[str, Any]],
    ) -> None:
        rid = response_id()
        model = chat_payload.get("_codex_requested_model", chat_payload["model"])
        try:
            with upstream_request(chat_payload, stream=False) as resp:
                upstream = json.loads(resp.read().decode("utf-8"))
        except BridgeError as exc:
            write_json(self, {"error": {"message": str(exc), "type": exc.typ}}, exc.status)
            return
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            write_json(self, {"error": {"message": err, "type": "upstream_error"}}, exc.code)
            return
        except Exception as exc:  # noqa: BLE001
            write_json(self, {"error": {"message": str(exc), "type": "upstream_error"}}, 502)
            return

        msg = ((upstream.get("choices") or [{}])[0].get("message") or {})
        text = msg.get("content") or ""
        outputs: list[dict[str, Any]] = []
        if text:
            outputs.append(build_message_item(text))
        for call in msg.get("tool_calls") or []:
            outputs.append(chat_tool_call_to_response(call))
        response = {
            "id": rid,
            "object": "response",
            "created_at": now(),
            "status": "completed",
            "model": model,
            "output": outputs,
            "usage": usage_from_chat(upstream.get("usage")),
        }
        assistant_msg: dict[str, Any] = {"role": "assistant", "content": text}
        if msg.get("tool_calls"):
            assistant_msg["tool_calls"] = msg["tool_calls"]
        RESPONSES[rid] = {"response": response, "chat_history": messages + [assistant_msg]}
        write_json(self, response)

    def handle_streaming(
        self,
        body: dict[str, Any],
        chat_payload: dict[str, Any],
        messages: list[dict[str, Any]],
    ) -> None:
        rid = response_id()
        model = chat_payload.get("_codex_requested_model", chat_payload["model"])
        created = now()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        seq = 0

        def emit(event: str, data: dict[str, Any]) -> None:
            nonlocal seq
            self.wfile.write(sse_payload(event, data, seq))
            self.wfile.flush()
            seq += 1

        def envelope(status: str, output: list[dict[str, Any]] | None = None) -> dict[str, Any]:
            return {
                "id": rid,
                "object": "response",
                "created_at": created,
                "status": status,
                "model": model,
                "output": output or [],
            }

        emit("response.created", {"type": "response.created", "response": envelope("in_progress")})

        msg_id = item_id("msg")
        message_open = False
        text_parts: list[str] = []
        tool_calls: dict[int, dict[str, Any]] = {}
        usage: dict[str, int] = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}

        def open_message() -> None:
            nonlocal message_open
            if message_open:
                return
            message_open = True
            emit("response.output_item.added", {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {
                    "id": msg_id,
                    "type": "message",
                    "status": "in_progress",
                    "role": "assistant",
                    "content": [],
                },
            })

        try:
            with upstream_request(chat_payload, stream=True) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    if chunk.get("usage"):
                        usage = usage_from_chat(chunk.get("usage"))
                    choice = (chunk.get("choices") or [{}])[0]
                    delta = choice.get("delta") or {}
                    if delta.get("content"):
                        open_message()
                        text = str(delta["content"])
                        text_parts.append(text)
                        emit("response.output_text.delta", {
                            "type": "response.output_text.delta",
                            "item_id": msg_id,
                            "output_index": 0,
                            "content_index": 0,
                            "delta": text,
                            "logprobs": [],
                        })
                    for tc in delta.get("tool_calls") or []:
                        idx = int(tc.get("index", 0))
                        stored = tool_calls.setdefault(idx, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                        if tc.get("id"):
                            stored["id"] = tc["id"]
                        if tc.get("type"):
                            stored["type"] = tc["type"]
                        fn = tc.get("function") or {}
                        if fn.get("name"):
                            stored["function"]["name"] = fn["name"]
                        if fn.get("arguments"):
                            stored["function"]["arguments"] += fn["arguments"]
        except BridgeError as exc:
            failed = envelope("failed")
            failed["error"] = {"message": str(exc), "type": exc.typ}
            emit("response.failed", {"type": "response.failed", "response": failed})
            return
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            failed = envelope("failed")
            failed["error"] = {"message": err, "type": "upstream_error"}
            emit("response.failed", {"type": "response.failed", "response": failed})
            return
        except Exception as exc:  # noqa: BLE001
            failed = envelope("failed")
            failed["error"] = {"message": str(exc), "type": "upstream_error"}
            emit("response.failed", {"type": "response.failed", "response": failed})
            return

        outputs: list[dict[str, Any]] = []
        final_text = "".join(text_parts)
        if message_open:
            emit("response.output_text.done", {
                "type": "response.output_text.done",
                "item_id": msg_id,
                "output_index": 0,
                "content_index": 0,
                "text": final_text,
                "logprobs": [],
            })
            msg_item = build_message_item(final_text, msg_id=msg_id)
            emit("response.output_item.done", {
                "type": "response.output_item.done",
                "output_index": 0,
                "item": msg_item,
            })
            outputs.append(msg_item)

        output_index = len(outputs)
        for _, call in sorted(tool_calls.items()):
            call_item = chat_tool_call_to_response(call)
            emit("response.output_item.added", {
                "type": "response.output_item.added",
                "output_index": output_index,
                "item": {**call_item, "status": "in_progress"},
            })
            emit("response.output_item.done", {
                "type": "response.output_item.done",
                "output_index": output_index,
                "item": call_item,
            })
            outputs.append(call_item)
            output_index += 1

        completed = envelope("completed", outputs)
        completed["usage"] = usage
        assistant_msg: dict[str, Any] = {"role": "assistant", "content": final_text}
        if tool_calls:
            assistant_msg["tool_calls"] = [tool_calls[i] for i in sorted(tool_calls)]
        RESPONSES[rid] = {"response": completed, "chat_history": messages + [assistant_msg]}
        emit("response.completed", {"type": "response.completed", "response": completed})


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    print(
        f"Codex cloud bridge listening on http://{HOST}:{PORT}/v1 "
        f"(nous -> {UPSTREAM_BASE} or {NOUS_DIRECT_BASE}, openrouter -> {OPENROUTER_BASE})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
