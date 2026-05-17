#!/usr/bin/env python3
"""Run one Hermes turn and emit Asclepius JSONL events.

This runs inside WSL. It is intentionally separate from codex_nous_bridge.py,
which runs on Windows and speaks the OpenAI Responses wire format to Codex.
The split keeps command execution in Hermes' own runtime while the bridge
remains responsible for UI/event translation.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Optional


HERMES_AGENT_ROOT = Path(os.environ.get("ASCLEPIUS_HERMES_AGENT_ROOT", "/home/agent/.hermes/hermes-agent"))
if str(HERMES_AGENT_ROOT) not in sys.path:
    sys.path.insert(0, str(HERMES_AGENT_ROOT))


def emit(event: dict[str, Any]) -> None:
    event.setdefault("at", time.time())
    sys.__stdout__.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
    sys.__stdout__.write("\n")
    sys.__stdout__.flush()


def normalize_toolsets(toolsets: object = None) -> list[str] | None:
    if not toolsets:
        return None
    raw_items = [toolsets] if isinstance(toolsets, str) else toolsets
    if not isinstance(raw_items, (list, tuple)):
        raw_items = [raw_items]
    normalized: list[str] = []
    for item in raw_items:
        if isinstance(item, str):
            normalized.extend(part.strip() for part in item.split(","))
        else:
            normalized.append(str(item).strip())
    return [item for item in normalized if item] or None


def create_session_db():
    try:
        from hermes_state import SessionDB

        return SessionDB()
    except Exception as exc:  # noqa: BLE001
        logging.debug("SQLite session store unavailable: %s", exc)
        return None


def clarify_callback(question: str, choices=None) -> str:
    if choices:
        return (
            "[asclepius non-interactive mode: pick the best option from "
            f"{choices} and continue.]"
        )
    return "[asclepius non-interactive mode: make a reasonable assumption and continue.]"


def resolve_agent_runtime(
    model: str,
    provider: str | None,
    session_db,
    toolsets: object = None,
    session_id: str | None = None,
    max_turns: int = 45,
):
    from hermes_cli.config import load_config
    from hermes_cli.models import detect_provider_for_model
    from hermes_cli.runtime_provider import resolve_runtime_provider
    from hermes_cli.tools_config import _get_platform_tools
    from run_agent import AIAgent

    cfg = load_config()
    model_cfg = cfg.get("model") or {}
    cfg_provider = ""
    if isinstance(model_cfg, dict):
        cfg_provider = str(model_cfg.get("provider") or "").strip().lower()

    effective_model = (model or "").strip()
    effective_provider: Optional[str] = (provider or "").strip() or None
    explicit_base_url_from_alias: Optional[str] = None

    if effective_provider is None and effective_model:
        try:
            from hermes_cli import model_switch as _ms

            _ms._ensure_direct_aliases()
            direct = _ms.DIRECT_ALIASES.get(effective_model.strip().lower())
        except Exception:
            direct = None
        if direct is not None:
            effective_model = direct.model
            effective_provider = direct.provider
            if direct.base_url:
                explicit_base_url_from_alias = direct.base_url.rstrip("/")
        else:
            current_provider = cfg_provider or os.getenv("HERMES_INFERENCE_PROVIDER", "").strip().lower() or "auto"
            detected = detect_provider_for_model(effective_model, current_provider)
            if detected:
                effective_provider, effective_model = detected

    runtime = resolve_runtime_provider(
        requested=effective_provider,
        target_model=effective_model or None,
        explicit_base_url=explicit_base_url_from_alias,
    )

    toolsets_list = normalize_toolsets(toolsets)
    if toolsets_list is None:
        # Match the programmatic API-server surface: full tools minus tools
        # that require an interactive chat user.
        toolsets_list = sorted(_get_platform_tools(cfg, "api_server"))
        if not toolsets_list:
            toolsets_list = sorted(_get_platform_tools(cfg, "cli"))

    agent = AIAgent(
        api_key=runtime.get("api_key"),
        base_url=runtime.get("base_url"),
        provider=runtime.get("provider"),
        api_mode=runtime.get("api_mode"),
        credential_pool=runtime.get("credential_pool"),
        model=effective_model,
        enabled_toolsets=toolsets_list,
        quiet_mode=True,
        verbose_logging=False,
        platform="api_server",
        session_id=session_id,
        session_db=session_db,
        max_iterations=max_turns,
        clarify_callback=clarify_callback,
        stream_delta_callback=lambda delta: emit({"type": "delta", "text": delta}) if delta is not None else None,
        tool_start_callback=lambda call_id, name, args: emit(
            {
                "type": "tool_started",
                "call_id": call_id,
                "name": name,
                "arguments": args or {},
            }
        ),
        tool_complete_callback=lambda call_id, name, args, result: emit(
            {
                "type": "tool_completed",
                "call_id": call_id,
                "name": name,
                "arguments": args or {},
                "result": result,
            }
        ),
    )
    agent.suppress_status_output = True
    return agent, effective_model, runtime


def main() -> int:
    logging.disable(logging.CRITICAL)
    os.environ["HERMES_YOLO_MODE"] = "1"
    os.environ["HERMES_ACCEPT_HOOKS"] = "1"

    if len(sys.argv) != 2:
        emit({"type": "error", "message": "usage: asclepius_hermes_event_runner.py request.json"})
        return 2

    request_path = Path(sys.argv[1])
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": f"failed to read request: {exc}"})
        return 2

    workdir = str(request.get("workdir") or "")
    if workdir:
        os.chdir(workdir)

    prompt = str(request.get("prompt") or "")
    model = str(request.get("model") or "")
    provider = str(request.get("provider") or "") or None
    session_id = str(request.get("session_id") or "") or None
    max_turns = int(request.get("max_turns") or 45)
    history = request.get("conversation_history")
    if not isinstance(history, list):
        history = []
    session_db = create_session_db()
    if session_id and not history and session_db is not None:
        try:
            history = session_db.get_messages_as_conversation(session_id) or []
        except Exception:
            history = []

    devnull = open(os.devnull, "w", encoding="utf-8")
    try:
        with contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
            agent, effective_model, runtime = resolve_agent_runtime(
                model=model,
                provider=provider,
                session_db=session_db,
                toolsets=request.get("toolsets"),
                session_id=session_id,
                max_turns=max_turns,
            )
            emit(
                {
                    "type": "started",
                    "session_id": getattr(agent, "session_id", session_id),
                    "model": effective_model,
                    "provider": runtime.get("provider"),
                    "base_url": runtime.get("base_url"),
                }
            )
            result = agent.run_conversation(
                user_message=prompt,
                conversation_history=history,
                task_id=getattr(agent, "session_id", session_id) or session_id,
            )
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": str(exc)})
        return 1
    finally:
        devnull.close()

    final_response = result.get("final_response", "") if isinstance(result, dict) else ""
    usage = {
        "input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
        "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
        "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
    }
    emit(
        {
            "type": "done",
            "session_id": getattr(agent, "session_id", session_id),
            "text": final_response,
            "usage": usage,
            "api_calls": result.get("api_calls", 0) if isinstance(result, dict) else 0,
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
