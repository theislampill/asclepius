#!/usr/bin/env python3
"""Local Responses API bridge for Codex -> Hermes Agent/cloud providers.

The default Codex app stays untouched. This bridge gives an isolated Codex
profile a Responses-compatible endpoint and routes turns through Hermes Agent
by default. A raw provider proxy mode is still available for diagnostics.
"""

from __future__ import annotations

import json
import hashlib
import os
import re
import shlex
import subprocess
import tempfile
import time
import uuid
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from math import ceil
from typing import Any


def windows_path_to_wsl(path: str) -> str:
    full = os.path.abspath(path)
    drive, rest = os.path.splitdrive(full)
    if not drive:
        return full.replace("\\", "/")
    drive_letter = drive.rstrip(":").lower()
    rest_wsl = rest.replace("\\", "/")
    return f"/mnt/{drive_letter}{rest_wsl}"


ROOT = os.path.dirname(os.path.abspath(__file__))
HOST = os.environ.get("CODEX_NOUS_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_NOUS_BRIDGE_PORT", "8655"))
UPSTREAM_BASE = os.environ.get("CODEX_NOUS_PROXY_BASE", "http://127.0.0.1:8645/v1").rstrip("/")
NOUS_DIRECT_BASE = os.environ.get("CODEX_NOUS_DIRECT_BASE", "https://inference-api.nousresearch.com/v1").rstrip("/")
OPENROUTER_BASE = os.environ.get("CODEX_OPENROUTER_BASE", "https://openrouter.ai/api/v1").rstrip("/")
SECRETS_PATH = os.environ.get("CODEX_CLOUD_SECRETS_PATH", os.path.join(ROOT, "cloud-secrets.json"))
CATALOG_PATH = os.environ.get("CODEX_CLOUD_MODELS_PATH", os.path.join(ROOT, "cloud-models.json"))
STATE_PATH = os.environ.get("CODEX_CLOUD_STATE_PATH", os.path.join(ROOT, "bridge-state.json"))
DEFAULT_MODEL = os.environ.get("CODEX_NOUS_DEFAULT_MODEL", "nous/deepseek/deepseek-v4-flash")
RUNTIME_MODE = os.environ.get("CODEX_CLOUD_RUNTIME_MODE", "hermes_agent").strip().lower()
HERMES_BIN = os.environ.get("CODEX_HERMES_BIN", "/home/agent/.local/bin/hermes")
HERMES_WSL_DISTRO = os.environ.get("CODEX_HERMES_WSL_DISTRO", "Ubuntu")
WINDOWS_WORKSPACE = os.environ.get("CODEX_CLOUD_WORKSPACE", r"C:\workspace\ai")
HERMES_WORKDIR = os.environ.get("CODEX_HERMES_WORKDIR", windows_path_to_wsl(WINDOWS_WORKSPACE))
HERMES_TIMEOUT_SECONDS = int(os.environ.get("CODEX_HERMES_TIMEOUT_SECONDS", "600"))
HERMES_HEARTBEAT_SECONDS = int(os.environ.get("CODEX_HERMES_HEARTBEAT_SECONDS", "15"))
HERMES_MAX_TURNS = int(os.environ.get("CODEX_HERMES_MAX_TURNS", "45"))
HERMES_PROGRESS_WORDS = os.environ.get("CODEX_HERMES_PROGRESS_WORDS", "1").strip().lower() not in {"0", "false", "no"}

RESPONSES: dict[str, dict[str, Any]] = {}


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


try:
    BRIDGE_SCRIPT_SHA256 = file_sha256(__file__)
except Exception:
    BRIDGE_SCRIPT_SHA256 = ""


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


def load_state() -> None:
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        responses = data.get("responses") if isinstance(data, dict) else None
        if isinstance(responses, dict):
            for rid, stored in responses.items():
                if isinstance(stored, dict) and isinstance(stored.get("response"), dict):
                    RESPONSES[str(rid)] = stored
    except FileNotFoundError:
        return
    except Exception:
        return


def save_state() -> None:
    try:
        trimmed = dict(list(RESPONSES.items())[-250:])
        payload = {"updated_at": now(), "responses": trimmed}
        tmp = f"{STATE_PATH}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
        os.replace(tmp, STATE_PATH)
    except Exception:
        return


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


def responses_body_to_prompt(body: dict[str, Any]) -> str:
    parts: list[str] = []
    instructions = flatten_content(body.get("instructions")).strip()
    if instructions:
        parts.append(f"System instructions from Codex:\n{instructions}")

    incoming = body.get("input")
    if isinstance(incoming, str):
        if incoming.strip():
            parts.append(incoming.strip())
    else:
        if isinstance(incoming, dict):
            incoming = [incoming]
        if isinstance(incoming, list):
            for entry in incoming:
                if isinstance(entry, str):
                    if entry.strip():
                        parts.append(entry.strip())
                    continue
                if not isinstance(entry, dict):
                    continue
                typ = entry.get("type")
                if typ == "function_call_output":
                    content = flatten_content(entry.get("output")).strip()
                    if content:
                        parts.append(f"Tool output:\n{content}")
                    continue
                role = entry.get("role") or "user"
                content = flatten_content(entry.get("content")).strip()
                if content:
                    parts.append(f"{role}:\n{content}")

    return "\n\n".join(parts).strip() or "Continue."


def codex_profile_config() -> dict[str, str]:
    config_path = os.path.join(ROOT, "codex-home", "config.toml")
    out: dict[str, str] = {}
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return out
    for key in ("sandbox_mode", "approval_policy", "model_reasoning_effort"):
        match = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*"([^"]*)"', text)
        if match:
            out[key] = match.group(1)
    return out


def request_shape_summary(body: dict[str, Any]) -> str:
    keys = sorted(str(key) for key in body.keys())
    tool_count = len(body.get("tools") or []) if isinstance(body.get("tools"), list) else 0
    prev = str(body.get("previous_response_id") or "")
    store = body.get("store")
    reasoning = body.get("reasoning")
    bits = [f"request_keys={keys}", f"tool_count={tool_count}"]
    if prev:
        bits.append(f"previous_response_id={prev}")
    if store is not None:
        bits.append(f"store={store}")
    if reasoning is not None:
        bits.append(f"reasoning={reasoning}")
    return "; ".join(bits)


def selected_model_metadata(route: dict[str, str]) -> dict[str, Any]:
    try:
        with open(CATALOG_PATH, "r", encoding="utf-8") as handle:
            catalog = json.load(handle)
    except Exception:
        return {}
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, list):
        return {}
    wanted = {route["requested_model"], route["requested_model"].replace(":", "/")}
    for model in models:
        if not isinstance(model, dict):
            continue
        if str(model.get("slug") or "") in wanted:
            return model
    for model in models:
        if not isinstance(model, dict):
            continue
        if str(model.get("provider") or "") == route["provider"] and str(model.get("model_id") or "") == route["upstream_model"]:
            return model
    return {}


def context_window_text(value: Any) -> str:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return "unknown"
    return f"{number:,} tokens"


def latest_context_status() -> dict[str, Any]:
    path = os.path.join(ROOT, "asclepius-context-status.json")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return {}
    latest = data.get("latest_thread") if isinstance(data, dict) else None
    return latest if isinstance(latest, dict) else {}


def runtime_capsule(body: dict[str, Any], route: dict[str, str]) -> str:
    profile = codex_profile_config()
    sandbox = profile.get("sandbox_mode", "unknown")
    approval = profile.get("approval_policy", "unknown")
    effort = profile.get("model_reasoning_effort", "unknown")
    wsl_workspace = windows_path_to_wsl(WINDOWS_WORKSPACE)
    context_status_path = os.path.join(ROOT, "asclepius-context-status.md")
    context_status_json = os.path.join(ROOT, "asclepius-context-status.json")
    context_status_wsl = windows_path_to_wsl(context_status_path)
    context_status_json_wsl = windows_path_to_wsl(context_status_json)
    metadata = selected_model_metadata(route)
    raw_context_value = metadata.get("context_length") or metadata.get("max_context_window") or metadata.get("context_window")
    raw_context_window = context_window_text(raw_context_value)
    status = latest_context_status()
    usable_context_value = status.get("context_window")
    if not usable_context_value and raw_context_value:
        try:
            usable_context_value = int(int(raw_context_value) * 0.95)
        except (TypeError, ValueError):
            usable_context_value = None
    usable_context_window = context_window_text(usable_context_value)
    context_tokens_used = context_window_text(status.get("context_tokens_used"))
    billing = metadata.get("billing_label") or metadata.get("billing") or "unknown"
    price = metadata.get("price_text") or "unknown price"
    return f"""Asclepius runtime capsule:
- You are running under Cloud-Codex/Asclepius, an isolated Codex Desktop profile backed by Hermes Agent.
- Do not identify as plain Codex only. If asked, say this is Codex Desktop as the frontend, Asclepius as the supervisor/profile, and Hermes Agent as the runtime.
- Active cloud route: provider={route["provider"]}; requested_model={route["requested_model"]}; upstream_model={route["upstream_model"]}.
- Context window truth: Codex usable context window={usable_context_window}; current completed-turn context used={context_tokens_used}; provider raw model max={raw_context_window}; billing={billing}; price={price}.
- Codex profile policy from config.toml: sandbox_mode={sandbox}; approval_policy={approval}; model_reasoning_effort={effort}.
- Important boundary: the visible Codex Desktop sandbox dropdown does not enforce Hermes tool execution. Hermes tools run inside the Hermes/WSL runtime. Treat the Codex policy above as binding.
- Host workspace: {WINDOWS_WORKSPACE}
- WSL workspace: {wsl_workspace}
- Hermes process working directory: {HERMES_WORKDIR}
- Use Linux/bash commands and WSL paths for Hermes tools. Convert Windows paths like C:\\workspace\\ai\\x to /mnt/c/workspace/ai/x before calling terminal/read/write tools.
- Do not use PowerShell cmdlets inside Hermes terminal unless you explicitly launch powershell.exe.
- Keep file reads bounded. Prefer listing/searching first, then read small ranges. Avoid repeatedly reading large generated files.
- If you need to alter files, keep edits inside the workspace unless the user explicitly asks otherwise.
- Each Codex chat should map to its own Hermes session through previous_response_id. Do not assume one global conversation.
- If the user asks about context usage, token counts, context window, compaction readiness, or whether the context reader is set, read Asclepius' corrected context status first:
  - Windows Markdown: {context_status_path}
  - Windows JSON: {context_status_json}
  - WSL Markdown: {context_status_wsl}
  - WSL JSON: {context_status_json_wsl}
- Treat that context status as the source of truth for completed turns. It is updated by Asclepius token sync after Hermes finishes a turn; the currently in-flight model call cannot be known until Hermes logs its usage.
- Tool-call parity note: Hermes tools run inside Hermes, not as native Codex tool widgets yet. Use the context status file's Hermes Tool Activity section when the user asks what tools ran.
- For compaction/resume turns, preserve task state, decisions, file paths, tool results, and Hermes session continuity. Keep summaries dense enough to survive the selected model context window.
- Bridge request shape: {request_shape_summary(body)}
"""


def strip_ansi(value: str) -> str:
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", value)


def parse_hermes_output(output: str) -> tuple[str, str | None]:
    clean = strip_ansi(output.replace("\r\n", "\n"))
    session_id: str | None = None
    final_lines: list[str] = []
    for line in clean.splitlines():
        stripped = line.strip()
        match = re.match(r"^(?:session_id|Session):\s*(\S+)", stripped, flags=re.IGNORECASE)
        if match:
            session_id = match.group(1)
            continue
        if stripped.startswith("Resume this session with:"):
            continue
        if stripped.startswith("hermes --resume "):
            maybe = stripped.rsplit(" ", 1)[-1].strip()
            if maybe:
                session_id = maybe
            continue
        if "Resumed session" in stripped:
            continue
        if stripped.startswith("Duration:") or stripped.startswith("Messages:"):
            continue
        final_lines.append(line)
    text = "\n".join(final_lines).strip()
    return text, session_id


def run_hermes_turn(route: dict[str, str], body: dict[str, Any], heartbeat=None) -> tuple[str, str | None, str]:
    prompt = build_hermes_prompt(body, route)
    prev = body.get("previous_response_id")
    resume_session = ""
    if prev and prev in RESPONSES:
        resume_session = str(RESPONSES[prev].get("hermes_session_id") or "")

    provider = route["provider"]
    upstream_model = route["upstream_model"]

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", dir=ROOT, delete=False) as handle:
        handle.write(prompt)
        prompt_path = handle.name
    hermes_bin_q = shlex.quote(HERMES_BIN)
    hermes_workdir_q = shlex.quote(HERMES_WORKDIR)
    script_text = f"""#!/usr/bin/env bash
set -euo pipefail
prompt_file="$1"
provider="$2"
model="$3"
resume_session="${{4:-}}"
prompt="$(cat "$prompt_file")"
cd {hermes_workdir_q}
args=({hermes_bin_q} chat -Q --source asclepius --provider "$provider" --model "$model" --max-turns {HERMES_MAX_TURNS} --query "$prompt")
if [ -n "$resume_session" ]; then
  args+=(--resume "$resume_session")
fi
exec "${{args[@]}}"
"""
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".sh", dir=ROOT, delete=False, newline="\n") as handle:
        handle.write(script_text)
        script_path = handle.name

    try:
        prompt_wsl = windows_path_to_wsl(prompt_path)
        script_wsl = windows_path_to_wsl(script_path)
        args = [
            "wsl.exe",
            "-d",
            HERMES_WSL_DISTRO,
            "--",
            "bash",
            script_wsl,
            prompt_wsl,
            provider,
            upstream_model,
            resume_session,
        ]
        if heartbeat is None:
            completed = subprocess.run(
                args,
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=HERMES_TIMEOUT_SECONDS,
            )
        else:
            proc = subprocess.Popen(
                args,
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            deadline = time.monotonic() + HERMES_TIMEOUT_SECONDS
            while True:
                try:
                    stdout, _ = proc.communicate(timeout=HERMES_HEARTBEAT_SECONDS)
                    completed = subprocess.CompletedProcess(args, proc.returncode, stdout or "", None)
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        proc.kill()
                        stdout, _ = proc.communicate()
                        raise BridgeError(
                            f"Hermes timed out after {HERMES_TIMEOUT_SECONDS} seconds.\n{stdout or ''}",
                            504,
                            "hermes_timeout",
                        )
                    heartbeat()
    finally:
        try:
            os.unlink(prompt_path)
        except OSError:
            pass
        try:
            os.unlink(script_path)
        except OSError:
            pass

    text, session_id = parse_hermes_output(completed.stdout or "")
    if completed.returncode != 0:
        message = text or completed.stdout or f"Hermes exited with code {completed.returncode}"
        raise BridgeError(message, 502, "hermes_runtime_error")
    return text or "(Hermes returned no final text.)", session_id or resume_session or None, prompt


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


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    # A conservative approximation for UI accounting when Hermes CLI does not
    # expose upstream token usage. This intentionally overcounts a little.
    by_chars = ceil(len(text) / 4)
    by_words = ceil(len(re.findall(r"\S+", text)) * 1.35)
    return max(1, by_chars, by_words)


def build_hermes_prompt(body: dict[str, Any], route: dict[str, str]) -> str:
    return f"{runtime_capsule(body, route)}\n\nUser/Codex request:\n{responses_body_to_prompt(body)}"


def response_text_for_usage(response: dict[str, Any]) -> str:
    chunks: list[str] = []
    for item in response.get("output") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "reasoning":
            for part in item.get("summary") or []:
                if isinstance(part, dict):
                    chunks.append(str(part.get("text") or ""))
            continue
        for part in item.get("content") or []:
            if isinstance(part, dict):
                chunks.append(str(part.get("text") or ""))
    return "\n".join(chunk for chunk in chunks if chunk)


def previous_context_tokens(body: dict[str, Any]) -> int:
    prev = body.get("previous_response_id")
    if prev and prev in RESPONSES:
        stored = RESPONSES[prev]
        try:
            context_tokens = int(stored.get("context_tokens") or 0)
            if context_tokens > 0:
                return context_tokens
        except (TypeError, ValueError):
            pass
        response = stored.get("response") if isinstance(stored, dict) else None
        if isinstance(response, dict):
            usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}
            try:
                total = int(usage.get("total_tokens") or 0)
                if total > 0:
                    return total
            except (TypeError, ValueError):
                pass
            # Older Asclepius builds stored zero usage. Recover enough context
            # to keep the UI meter and compaction heuristics from thinking the
            # prior turn was empty.
            recovered = estimate_tokens(response_text_for_usage(response))
            if recovered > 0:
                return recovered + 500
    return 0


def read_hermes_accounting(session_id: str | None) -> dict[str, Any] | None:
    if not session_id:
        return None
    script = r"""
import json
import re
import sqlite3
import sys
from pathlib import Path

session_id = sys.argv[1]
home = Path.home() / ".hermes"
db_path = home / "state.db"
result = {"session_id": session_id, "db": None, "api_calls": []}

if db_path.exists():
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    try:
        row = con.execute(
            "SELECT input_tokens, output_tokens, cache_read_tokens, "
            "cache_write_tokens, reasoning_tokens, api_call_count "
            "FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        if row is not None:
            result["db"] = dict(row)
    finally:
        con.close()

log_path = home / "logs" / "agent.log"
if log_path.exists():
    pattern = re.compile(
        r"\[" + re.escape(session_id) + r"\].*API call #(?P<call>\d+):"
        r".*?\bin=(?P<input>\d+)\s+out=(?P<output>\d+)\s+total=(?P<total>\d+)"
        r"(?:.*?\bcache=(?P<cache_read>\d+)/(?P<cache_prompt>\d+))?"
    )
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = pattern.search(line)
                if not match:
                    continue
                result["api_calls"].append({
                    "call_number": int(match.group("call")),
                    "prompt_tokens": int(match.group("input")),
                    "output_tokens": int(match.group("output")),
                    "total_tokens": int(match.group("total")),
                    "cache_read_tokens": int(match.group("cache_read") or 0),
                })
    except OSError:
        pass

print(json.dumps(result, separators=(",", ":")))
"""
    try:
        completed = subprocess.run(
            ["wsl.exe", "-d", HERMES_WSL_DISTRO, "--", "python3", "-c", script, session_id],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    try:
        data = json.loads(completed.stdout or "{}")
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return data


def accounting_prompt_tokens(accounting: dict[str, Any] | None) -> int:
    if not accounting:
        return 0
    db = accounting.get("db")
    if not isinstance(db, dict):
        return 0
    total = 0
    for key in ("input_tokens", "cache_read_tokens", "cache_write_tokens"):
        try:
            total += int(db.get(key) or 0)
        except (TypeError, ValueError):
            pass
    return total


def accounting_output_tokens(accounting: dict[str, Any] | None) -> int:
    if not accounting:
        return 0
    db = accounting.get("db")
    if not isinstance(db, dict):
        return 0
    total = 0
    for key in ("output_tokens", "reasoning_tokens"):
        try:
            total += int(db.get(key) or 0)
        except (TypeError, ValueError):
            pass
    return total


def accounting_api_call_count(accounting: dict[str, Any] | None) -> int:
    if not accounting:
        return 0
    calls = accounting.get("api_calls")
    if isinstance(calls, list) and calls:
        return len(calls)
    db = accounting.get("db")
    if isinstance(db, dict):
        try:
            return int(db.get("api_call_count") or 0)
        except (TypeError, ValueError):
            return 0
    return 0


def previous_accounting(body: dict[str, Any], session_id: str | None) -> dict[str, Any] | None:
    prev = body.get("previous_response_id")
    if not (prev and prev in RESPONSES and session_id):
        return None
    stored = RESPONSES[prev]
    if str(stored.get("hermes_session_id") or "") != str(session_id):
        return None
    accounting = stored.get("hermes_accounting")
    return accounting if isinstance(accounting, dict) else None


def actual_hermes_usage(
    body: dict[str, Any],
    session_id: str | None,
    accounting: dict[str, Any] | None,
    output: str,
    progress: str = "",
) -> tuple[dict[str, int] | None, dict[str, Any]]:
    if not accounting:
        return None, {}
    prior = previous_accounting(body, session_id)
    prompt_delta = accounting_prompt_tokens(accounting) - accounting_prompt_tokens(prior)
    output_delta = accounting_output_tokens(accounting) - accounting_output_tokens(prior)
    api_delta = accounting_api_call_count(accounting) - accounting_api_call_count(prior)
    if prompt_delta < 0:
        prompt_delta = accounting_prompt_tokens(accounting)
    if output_delta < 0:
        output_delta = accounting_output_tokens(accounting)
    if api_delta < 0:
        api_delta = accounting_api_call_count(accounting)

    api_calls = accounting.get("api_calls") if isinstance(accounting.get("api_calls"), list) else []
    prior_call_count = accounting_api_call_count(prior)
    new_calls = api_calls[prior_call_count:] if prior and prior_call_count <= len(api_calls) else api_calls
    last_prompt_tokens = 0
    if new_calls:
        try:
            last_prompt_tokens = int(new_calls[-1].get("prompt_tokens") or 0)
        except (TypeError, ValueError):
            last_prompt_tokens = 0

    # Codex's context meter needs the live prompt/context size, not cached
    # billable deltas. Hermes' log line is emitted from normalized provider
    # usage, so prefer the last upstream prompt for compaction accounting.
    input_tokens = last_prompt_tokens or prompt_delta
    if input_tokens <= 0:
        return None, {}
    if output_delta <= 0:
        output_delta = estimate_tokens(output) + estimate_tokens(progress)
    usage = {
        "input_tokens": input_tokens,
        "output_tokens": output_delta,
        "total_tokens": input_tokens + output_delta,
    }
    details = {
        "usage_source": "hermes_actual",
        "context_tokens": input_tokens,
        "prompt_tokens_sum": prompt_delta,
        "api_call_count": api_delta,
    }
    return usage, details


def estimated_hermes_usage(body: dict[str, Any], prompt: str, output: str, progress: str = "") -> dict[str, int]:
    current_input = estimate_tokens(prompt)
    prior_context = previous_context_tokens(body)
    input_tokens = prior_context + current_input
    output_tokens = estimate_tokens(output) + estimate_tokens(progress)
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
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


def text_chunks(text: str, width: int = 80) -> list[str]:
    if not text:
        return []
    return re.findall(rf".{{1,{width}}}(?:\s+|$)", text, flags=re.DOTALL) or [text]


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
                "runtime_mode": RUNTIME_MODE,
                "bridge_script_sha256": BRIDGE_SCRIPT_SHA256,
                "hermes_bin": HERMES_BIN,
                "hermes_wsl_distro": HERMES_WSL_DISTRO,
                "hermes_workdir": HERMES_WORKDIR,
                "windows_workspace": WINDOWS_WORKSPACE,
                "hermes_max_turns": HERMES_MAX_TURNS,
                "tracked_responses": len(RESPONSES),
                "session_mapping": "bridge-state.json maps Codex response ids to Hermes session ids; current Hermes may still record source as cli",
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
            save_state()
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
        if RUNTIME_MODE in {"hermes", "hermes_agent", "agent"}:
            if stream:
                self.handle_hermes_streaming(body, route)
            else:
                self.handle_hermes_non_streaming(body, route)
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

    def handle_hermes_non_streaming(self, body: dict[str, Any], route: dict[str, str]) -> None:
        rid = response_id()
        model = route["requested_model"]
        try:
            text, hermes_session_id, hermes_prompt = run_hermes_turn(route, body)
        except BridgeError as exc:
            write_json(self, {"error": {"message": str(exc), "type": exc.typ}}, exc.status)
            return
        except Exception as exc:  # noqa: BLE001
            write_json(self, {"error": {"message": str(exc), "type": "hermes_runtime_error"}}, 502)
            return

        output = build_message_item(text)
        hermes_accounting = read_hermes_accounting(hermes_session_id)
        usage, usage_details = actual_hermes_usage(body, hermes_session_id, hermes_accounting, text)
        if usage is None:
            usage = estimated_hermes_usage(body, hermes_prompt, text)
            usage_details = {
                "usage_source": "bridge_estimate",
                "context_tokens": usage["input_tokens"],
                "prompt_tokens_sum": usage["input_tokens"],
                "api_call_count": None,
            }
        response = {
            "id": rid,
            "object": "response",
            "created_at": now(),
            "status": "completed",
            "model": model,
            "output": [output],
            "usage": usage,
            "metadata": {
                "runtime": "hermes_agent",
                "hermes_session_id": hermes_session_id,
                "provider": route["provider"],
                "upstream_model": route["upstream_model"],
                "usage_source": usage_details["usage_source"],
                "hermes_context_tokens": usage_details["context_tokens"],
                "hermes_prompt_tokens_sum": usage_details["prompt_tokens_sum"],
                "hermes_api_call_count": usage_details["api_call_count"],
            },
        }
        RESPONSES[rid] = {
            "response": response,
            "chat_history": [],
            "hermes_session_id": hermes_session_id,
            "hermes_accounting": hermes_accounting,
            "context_tokens": usage_details["context_tokens"],
        }
        save_state()
        write_json(self, response)

    def handle_hermes_streaming(self, body: dict[str, Any], route: dict[str, str]) -> None:
        rid = response_id()
        model = route["requested_model"]
        created = now()
        started_at = time.monotonic()
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
                "metadata": {
                    "runtime": "hermes_agent",
                    "provider": route["provider"],
                    "upstream_model": route["upstream_model"],
                },
            }

        emit("response.created", {"type": "response.created", "response": envelope("in_progress")})
        reasoning_id = item_id("rs")
        emit("response.output_item.added", {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "id": reasoning_id,
                "type": "reasoning",
                "status": "in_progress",
                "summary": [],
            },
        })
        emit("response.reasoning_summary_part.added", {
            "type": "response.reasoning_summary_part.added",
            "item_id": reasoning_id,
            "output_index": 0,
            "summary_index": 0,
            "part": {"type": "summary_text", "text": ""},
        })

        reasoning_text: list[str] = []

        def emit_progress(text: str) -> None:
            if not HERMES_PROGRESS_WORDS:
                emit("response.in_progress", {"type": "response.in_progress", "response": envelope("in_progress")})
                return
            elapsed = int(time.monotonic() - started_at)
            line = f"Asclepius/Hermes: {text} ({elapsed}s elapsed)\n"
            reasoning_text.append(line)
            emit("response.reasoning_summary_text.delta", {
                "type": "response.reasoning_summary_text.delta",
                "item_id": reasoning_id,
                "output_index": 0,
                "summary_index": 0,
                "delta": line,
            })
            emit("response.in_progress", {"type": "response.in_progress", "response": envelope("in_progress")})

        metadata = selected_model_metadata(route)
        context_label = context_window_text(metadata.get("context_length"))
        emit_progress(
            f"started Hermes Agent route {route['requested_model']} via {route['provider']}; "
            f"context window {context_label}"
        )

        msg_id = item_id("msg")
        emit("response.output_item.added", {
            "type": "response.output_item.added",
            "output_index": 1,
            "item": {
                "id": msg_id,
                "type": "message",
                "status": "in_progress",
                "role": "assistant",
                "content": [],
            },
        })

        try:
            def heartbeat() -> None:
                emit_progress(f"still running; max-turn budget {HERMES_MAX_TURNS}")

            text, hermes_session_id, hermes_prompt = run_hermes_turn(route, body, heartbeat=heartbeat)
        except BridgeError as exc:
            failed = envelope("failed")
            failed["error"] = {"message": str(exc), "type": exc.typ}
            emit("response.failed", {"type": "response.failed", "response": failed})
            return
        except Exception as exc:  # noqa: BLE001
            failed = envelope("failed")
            failed["error"] = {"message": str(exc), "type": "hermes_runtime_error"}
            emit("response.failed", {"type": "response.failed", "response": failed})
            return

        emit_progress("Hermes Agent finished; streaming final answer into Codex")
        reasoning_done = "".join(reasoning_text)
        emit("response.reasoning_summary_text.done", {
            "type": "response.reasoning_summary_text.done",
            "item_id": reasoning_id,
            "output_index": 0,
            "summary_index": 0,
            "text": reasoning_done,
        })
        emit("response.reasoning_summary_part.done", {
            "type": "response.reasoning_summary_part.done",
            "item_id": reasoning_id,
            "output_index": 0,
            "summary_index": 0,
            "part": {"type": "summary_text", "text": reasoning_done},
        })
        reasoning_item = {
            "id": reasoning_id,
            "type": "reasoning",
            "status": "completed",
            "summary": [{"type": "summary_text", "text": reasoning_done}],
        }
        emit("response.output_item.done", {
            "type": "response.output_item.done",
            "output_index": 0,
            "item": reasoning_item,
        })

        # Hermes CLI currently returns final text after its own agent loop. Emit
        # the final answer as a synthetic stream so Codex's app protocol still
        # receives incremental output text events once Hermes returns control.
        for chunk in text_chunks(text):
            emit("response.output_text.delta", {
                "type": "response.output_text.delta",
                "item_id": msg_id,
                "output_index": 1,
                "content_index": 0,
                "delta": chunk,
                "logprobs": [],
            })

        emit("response.output_text.done", {
            "type": "response.output_text.done",
            "item_id": msg_id,
            "output_index": 1,
            "content_index": 0,
            "text": text,
            "logprobs": [],
        })
        msg_item = build_message_item(text, msg_id=msg_id)
        emit("response.output_item.done", {
            "type": "response.output_item.done",
            "output_index": 1,
            "item": msg_item,
        })
        completed = envelope("completed", [reasoning_item, msg_item])
        hermes_accounting = read_hermes_accounting(hermes_session_id)
        usage, usage_details = actual_hermes_usage(body, hermes_session_id, hermes_accounting, text, reasoning_done)
        if usage is None:
            usage = estimated_hermes_usage(body, hermes_prompt, text, reasoning_done)
            usage_details = {
                "usage_source": "bridge_estimate",
                "context_tokens": usage["input_tokens"],
                "prompt_tokens_sum": usage["input_tokens"],
                "api_call_count": None,
            }
        completed["usage"] = usage
        completed["metadata"]["hermes_session_id"] = hermes_session_id
        completed["metadata"]["usage_source"] = usage_details["usage_source"]
        completed["metadata"]["hermes_context_tokens"] = usage_details["context_tokens"]
        completed["metadata"]["hermes_prompt_tokens_sum"] = usage_details["prompt_tokens_sum"]
        completed["metadata"]["hermes_api_call_count"] = usage_details["api_call_count"]
        RESPONSES[rid] = {
            "response": completed,
            "chat_history": [],
            "hermes_session_id": hermes_session_id,
            "hermes_accounting": hermes_accounting,
            "context_tokens": usage_details["context_tokens"],
        }
        save_state()
        emit("response.completed", {"type": "response.completed", "response": completed})

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
        save_state()
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
        save_state()
        emit("response.completed", {"type": "response.completed", "response": completed})


def main() -> None:
    load_state()
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    print(
        f"Codex cloud bridge listening on http://{HOST}:{PORT}/v1 "
        f"(runtime={RUNTIME_MODE}, nous -> {UPSTREAM_BASE} or {NOUS_DIRECT_BASE}, "
        f"openrouter -> {OPENROUTER_BASE})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
