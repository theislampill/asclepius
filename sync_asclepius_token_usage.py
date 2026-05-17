#!/usr/bin/env python3
"""Sync Hermes token usage into the isolated Codex desktop state.

Codex Desktop currently records zero token usage for Asclepius' custom
Responses provider even when the bridge returns upstream usage. This sidecar is
Asclepius-only: it reads the isolated CODEX_HOME rollouts, maps completed turns
to Hermes Agent API-call accounting, and backfills Codex's local token_count
events plus the thread summary counter.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SESSION_RE = re.compile(r"(?:HERMES_SESSION_ID=)?([0-9]{8}_[0-9]{6}_[0-9a-f]+)")
API_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(?P<ms>\d{3}) "
    r"INFO \[(?P<session>[^\]]+)\].*API call #(?P<call>\d+):"
    r".*?\bin=(?P<input>\d+)\s+out=(?P<output>\d+)\s+total=(?P<total>\d+)"
    r"(?:.*?\bcache=(?P<cache_read>\d+)/(?P<cache_prompt>\d+))?"
)
TOOL_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(?P<ms>\d{3}) "
    r"(?P<level>INFO|WARNING|ERROR) \[(?P<session>[^\]]+)\] "
    r"run_agent: (?:tool|Tool) (?P<tool>[A-Za-z0-9_.-]+) "
    r"(?P<status>completed|returned error) \((?P<duration>[^),]+)"
    r"(?:,\s*(?P<chars>\d+)\s*chars)?\)(?::\s*(?P<detail>.*))?"
)


@dataclass
class ApiCall:
    epoch: float
    session_id: str
    call_number: int
    input_tokens: int
    output_tokens: int
    total_tokens: int
    cache_read_tokens: int


@dataclass
class TurnUsage:
    input_tokens: int
    cached_input_tokens: int
    output_tokens: int
    reasoning_output_tokens: int
    total_tokens: int
    session_id: str


@dataclass
class ToolEvent:
    epoch: float
    session_id: str
    tool: str
    status: str
    duration: str
    output_chars: int | None
    detail: str | None


def parse_local_log_time(value: str, ms: str) -> float:
    dt = datetime.strptime(f"{value}.{ms}", "%Y-%m-%d %H:%M:%S.%f")
    return dt.timestamp()


def read_api_calls(log_path: Path) -> list[ApiCall]:
    if not log_path.exists():
        return []
    calls: list[ApiCall] = []
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = API_RE.search(line)
                if not match:
                    continue
                calls.append(
                    ApiCall(
                        epoch=parse_local_log_time(match.group("ts"), match.group("ms")),
                        session_id=match.group("session"),
                        call_number=int(match.group("call")),
                        input_tokens=int(match.group("input")),
                        output_tokens=int(match.group("output")),
                        total_tokens=int(match.group("total")),
                        cache_read_tokens=int(match.group("cache_read") or 0),
                    )
                )
    except OSError:
        return []
    return calls


def read_tool_events(log_path: Path) -> list[ToolEvent]:
    if not log_path.exists():
        return []
    events: list[ToolEvent] = []
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = TOOL_RE.search(line)
                if not match:
                    continue
                chars = match.group("chars")
                events.append(
                    ToolEvent(
                        epoch=parse_local_log_time(match.group("ts"), match.group("ms")),
                        session_id=match.group("session"),
                        tool=match.group("tool"),
                        status="error" if match.group("status") == "returned error" else "completed",
                        duration=match.group("duration"),
                        output_chars=int(chars) if chars else None,
                        detail=(match.group("detail") or "").strip() or None,
                    )
                )
    except OSError:
        return []
    return events


def hermes_log_path(distro: str) -> Path:
    for root in (
        Path(f"//wsl.localhost/{distro}"),
        Path(f"//wsl$/{distro}"),
    ):
        candidate = root / "home" / "agent" / ".hermes" / "logs" / "agent.log"
        if candidate.exists():
            return candidate
    return Path(r"\\wsl.localhost") / distro / "home" / "agent" / ".hermes" / "logs" / "agent.log"


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                return []
    return rows


def dump_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            handle.write("\n")
    os.replace(tmp, path)


def append_token_count_correction(path: Path, info: dict[str, Any], session_id: str) -> bool:
    row = {
        "timestamp": datetime.utcnow().isoformat(timespec="milliseconds") + "Z",
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": info,
            "asclepius_usage_source": "hermes_agent_log_append",
            "hermes_session_id": session_id,
        },
    }
    try:
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            handle.write("\n")
        return True
    except OSError:
        return False


def payload_type(row: dict[str, Any]) -> str:
    payload = row.get("payload")
    if not isinstance(payload, dict):
        return ""
    return str(payload.get("type") or "")


def token_info_is_zero(info: Any) -> bool:
    if not isinstance(info, dict):
        return True
    total = info.get("total_token_usage")
    if not isinstance(total, dict):
        return True
    try:
        return int(total.get("total_tokens") or 0) <= 0
    except (TypeError, ValueError):
        return True


def find_session_hint(rows: list[dict[str, Any]], start_idx: int, end_idx: int) -> str | None:
    for row in rows[start_idx : end_idx + 1]:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        for key in ("message", "last_agent_message"):
            value = payload.get(key)
            if not isinstance(value, str):
                continue
            match = SESSION_RE.search(value)
            if match:
                return match.group(1)
    return None


def calls_for_turn(
    calls: list[ApiCall],
    started_at: float,
    completed_at: float,
    session_hint: str | None,
) -> list[ApiCall]:
    window = [
        call
        for call in calls
        if started_at - 60 <= call.epoch <= completed_at + 60
        and (not session_hint or call.session_id == session_hint)
    ]
    if window:
        return window
    if session_hint:
        hinted = [call for call in calls if call.session_id == session_hint]
        if hinted:
            return hinted
    return []


def usage_from_calls(calls: list[ApiCall]) -> TurnUsage | None:
    if not calls:
        return None
    calls = sorted(calls, key=lambda call: (call.epoch, call.call_number))
    last = calls[-1]
    output_tokens = sum(call.output_tokens for call in calls)
    input_tokens = last.input_tokens
    total_tokens = input_tokens + output_tokens
    return TurnUsage(
        input_tokens=input_tokens,
        cached_input_tokens=last.cache_read_tokens,
        output_tokens=output_tokens,
        reasoning_output_tokens=0,
        total_tokens=total_tokens,
        session_id=last.session_id,
    )


def usage_info(usage: TurnUsage, context_window: int | None) -> dict[str, Any]:
    payload = {
        "total_token_usage": {
            "input_tokens": usage.input_tokens,
            "cached_input_tokens": usage.cached_input_tokens,
            "output_tokens": usage.output_tokens,
            "reasoning_output_tokens": usage.reasoning_output_tokens,
            "total_tokens": usage.total_tokens,
        },
        "last_token_usage": {
            "input_tokens": usage.input_tokens,
            "cached_input_tokens": usage.cached_input_tokens,
            "output_tokens": usage.output_tokens,
            "reasoning_output_tokens": usage.reasoning_output_tokens,
            "total_tokens": usage.total_tokens,
        },
    }
    if context_window:
        payload["model_context_window"] = context_window
    return payload


def token_total(info: Any) -> int | None:
    if not isinstance(info, dict):
        return None
    total = info.get("total_token_usage")
    if not isinstance(total, dict):
        return None
    try:
        value = int(total.get("total_tokens") or 0)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def latest_rollout_context(path: Path) -> dict[str, Any] | None:
    rows = load_jsonl(path)
    if not rows:
        return None

    thread_id = None
    title = None
    model = None
    model_provider = None
    context_window = None
    latest_info = None
    latest_session_id = None
    latest_session_hint = None
    usage_source = None
    latest_timestamp = None

    for row in rows:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        if row.get("type") == "session_meta":
            thread_id = payload.get("id") or thread_id
            title = payload.get("title") or title
            model_provider = payload.get("model_provider") or model_provider
        if payload.get("type") == "task_started":
            model = payload.get("model") or model
            context_window = payload.get("model_context_window") or context_window
        for key in ("message", "last_agent_message"):
            value = payload.get(key)
            if not isinstance(value, str):
                continue
            match = SESSION_RE.search(value)
            if match:
                latest_session_hint = match.group(1)

    for row in reversed(rows):
        payload = row.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        if token_total(info) is None:
            continue
        latest_info = info
        latest_session_id = payload.get("hermes_session_id")
        usage_source = payload.get("asclepius_usage_source") or "codex_token_count"
        latest_timestamp = row.get("timestamp")
        break

    if latest_info is None:
        return None
    total = latest_info.get("total_token_usage") or {}
    last = latest_info.get("last_token_usage") or {}
    try:
        context_window_int = int(latest_info.get("model_context_window") or context_window or 0)
    except (TypeError, ValueError):
        context_window_int = 0
    session_total_tokens = int(total.get("total_tokens") or 0)
    context_tokens_used = int(last.get("total_tokens") or session_total_tokens)
    remaining = max(context_window_int - context_tokens_used, 0) if context_window_int else None
    percent = round((context_tokens_used / context_window_int) * 100, 2) if context_window_int else None
    return {
        "thread_id": thread_id,
        "title": title,
        "rollout_path": str(path),
        "model_provider": model_provider,
        "model": model,
        "hermes_session_id": latest_session_id or latest_session_hint,
        "usage_source": usage_source,
        "updated_at": latest_timestamp,
        "context_window": context_window_int or None,
        "context_tokens_used": context_tokens_used,
        "session_cumulative_tokens": session_total_tokens,
        "remaining_tokens": remaining,
        "percent_used": percent,
        "total_token_usage": total,
        "last_token_usage": last,
    }


def backfill_rollout(path: Path, calls: list[ApiCall]) -> tuple[bool, int | None]:
    rows = load_jsonl(path)
    if not rows:
        return False, None

    changed = False
    latest_info: dict[str, Any] | None = None
    latest_session_id: str | None = None
    latest_total: int | None = None
    idx = 0
    while idx < len(rows):
        row = rows[idx]
        if row.get("type") != "event_msg" or payload_type(row) != "task_started":
            idx += 1
            continue

        start_idx = idx
        payload = row.get("payload") or {}
        started_at = float(payload.get("started_at") or 0)
        context_window = payload.get("model_context_window")
        try:
            context_window_int = int(context_window) if context_window else None
        except (TypeError, ValueError):
            context_window_int = None

        end_idx = start_idx
        completed_at = started_at
        for probe in range(start_idx + 1, len(rows)):
            end_idx = probe
            probe_payload = rows[probe].get("payload")
            if isinstance(probe_payload, dict) and probe_payload.get("type") == "task_complete":
                completed_at = float(probe_payload.get("completed_at") or started_at)
                break

        token_rows = [
            i for i in range(start_idx, end_idx + 1)
            if rows[i].get("type") == "event_msg" and payload_type(rows[i]) == "token_count"
        ]
        final_token_idx = token_rows[-1] if token_rows else None
        if final_token_idx is None:
            idx = end_idx + 1
            continue

        info = (rows[final_token_idx].get("payload") or {}).get("info")
        if not token_info_is_zero(info):
            try:
                latest_total = int(info["total_token_usage"]["total_tokens"])
            except Exception:
                pass
            idx = end_idx + 1
            continue

        correction_total: int | None = None
        for probe in range(end_idx + 1, len(rows)):
            probe_payload = rows[probe].get("payload")
            if isinstance(probe_payload, dict) and probe_payload.get("type") == "task_started":
                break
            if not isinstance(probe_payload, dict) or probe_payload.get("type") != "token_count":
                continue
            if not str(probe_payload.get("asclepius_usage_source") or "").startswith("hermes_agent_log"):
                continue
            correction_info = probe_payload.get("info")
            if token_info_is_zero(correction_info):
                continue
            try:
                correction_total = int(correction_info["total_token_usage"]["total_tokens"])
            except Exception:
                correction_total = None
            break
        if correction_total is not None:
            latest_total = correction_total
            idx = end_idx + 1
            continue

        session_hint = find_session_hint(rows, start_idx, end_idx)
        usage = usage_from_calls(calls_for_turn(calls, started_at, completed_at, session_hint))
        if usage is None:
            idx = end_idx + 1
            continue

        info_payload = usage_info(usage, context_window_int)
        rows[final_token_idx]["payload"]["info"] = info_payload
        rows[final_token_idx]["payload"]["asclepius_usage_source"] = "hermes_agent_log"
        rows[final_token_idx]["payload"]["hermes_session_id"] = usage.session_id
        latest_total = usage.total_tokens
        latest_info = info_payload
        latest_session_id = usage.session_id
        changed = True
        idx = end_idx + 1

    if changed:
        backup = path.with_suffix(path.suffix + ".asclepius-token-sync.bak")
        if not backup.exists():
            try:
                backup.write_bytes(path.read_bytes())
            except OSError:
                pass
        try:
            dump_jsonl(path, rows)
        except PermissionError:
            if latest_info and latest_session_id:
                append_token_count_correction(path, latest_info, latest_session_id)
    return changed, latest_total


def sync_threads_db(codex_home: Path, totals: dict[str, int]) -> int:
    db_path = codex_home / "state_5.sqlite"
    if not db_path.exists() or not totals:
        return 0
    con = sqlite3.connect(str(db_path), timeout=5)
    try:
        changed = 0
        for rollout_path, total in totals.items():
            cur = con.execute(
                "UPDATE threads SET tokens_used = ? WHERE rollout_path = ? AND tokens_used != ?",
                (total, rollout_path, total),
            )
            changed += cur.rowcount if cur.rowcount is not None else 0
        con.commit()
        return changed
    finally:
        con.close()


def load_thread_metadata(codex_home: Path) -> dict[str, dict[str, Any]]:
    db_path = codex_home / "state_5.sqlite"
    if not db_path.exists():
        return {}
    con = sqlite3.connect(str(db_path), timeout=5)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            """
            SELECT id, title, model_provider, model, reasoning_effort,
                   tokens_used, updated_at, rollout_path
            FROM threads
            """
        ).fetchall()
        return {str(row["rollout_path"]): dict(row) for row in rows}
    finally:
        con.close()


def load_provider_context_windows(root: Path) -> dict[str, int]:
    out: dict[str, int] = {}
    for name in ("cloud-models.json", "codex-model-catalog.json"):
        path = root / name
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        models = data.get("models") if isinstance(data, dict) else data
        if not isinstance(models, list):
            continue
        for model in models:
            if not isinstance(model, dict):
                continue
            slug = str(model.get("slug") or model.get("id") or "")
            if not slug:
                continue
            value = (
                model.get("context_length")
                or model.get("max_context_window")
                or model.get("context_window")
            )
            try:
                number = int(value)
            except (TypeError, ValueError):
                continue
            if number > 0:
                out[slug] = max(out.get(slug, 0), number)
    return out


def write_context_status(
    root: Path,
    contexts: list[dict[str, Any]],
    codex_home: Path,
    tool_events: list[ToolEvent],
) -> None:
    thread_meta = load_thread_metadata(codex_home)
    provider_context_windows = load_provider_context_windows(root)
    enriched: list[dict[str, Any]] = []
    for context in contexts:
        item = dict(context)
        meta = thread_meta.get(item.get("rollout_path") or "")
        if meta:
            item["thread_id"] = meta.get("id") or item.get("thread_id")
            item["title"] = meta.get("title") or item.get("title")
            item["model_provider"] = meta.get("model_provider") or item.get("model_provider")
            item["model"] = meta.get("model") or item.get("model")
            item["reasoning_effort"] = meta.get("reasoning_effort")
            item["tokens_used_row"] = meta.get("tokens_used")
            item["thread_updated_at"] = meta.get("updated_at")
        model_slug = str(item.get("model") or "")
        if model_slug and provider_context_windows.get(model_slug):
            item["provider_raw_context_window"] = provider_context_windows[model_slug]
        enriched.append(item)

    def sort_key(item: dict[str, Any]) -> tuple[float, float]:
        path = item.get("rollout_path") or ""
        try:
            mtime = Path(path).stat().st_mtime
        except OSError:
            mtime = 0.0
        try:
            updated = float(item.get("thread_updated_at") or 0)
        except (TypeError, ValueError):
            updated = 0.0
        return (max(updated, mtime), mtime)

    latest = max(enriched, key=sort_key) if enriched else None
    if latest and latest.get("hermes_session_id"):
        session_tools = [
            event for event in tool_events
            if event.session_id == latest.get("hermes_session_id")
        ]
        latest["tool_activity"] = {
            "session_id": latest.get("hermes_session_id"),
            "total_tool_events": len(session_tools),
            "error_tool_events": sum(1 for event in session_tools if event.status == "error"),
            "events": [
                {
                    "time": datetime.fromtimestamp(event.epoch, timezone.utc).isoformat(timespec="seconds"),
                    "tool": event.tool,
                    "status": event.status,
                    "duration": event.duration,
                    "output_chars": event.output_chars,
                    "detail": event.detail,
                }
                for event in sorted(session_tools, key=lambda item: item.epoch)[-25:]
            ],
        }
    generated_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    status = {
        "generated_at": generated_at,
        "source": "asclepius_token_sync",
        "notes": [
            "Use this file as the Asclepius context/token source of truth.",
            "Codex usable context window is the true window Codex enforces for the current profile and auto-compaction.",
            "Provider raw context window is the upstream model maximum before Codex reserves headroom.",
            "Hermes tool activity is parsed from Hermes Agent logs; it is not yet native Codex tool-call UI.",
            "It is updated after completed Hermes turns; an in-flight model call is not final until Hermes logs usage.",
            "Counts come from Hermes Agent provider usage logs and Codex's isolated rollout state.",
        ],
        "latest_thread": latest,
        "threads": sorted(enriched, key=sort_key, reverse=True)[:25],
    }
    json_path = root / "asclepius-context-status.json"
    md_path = root / "asclepius-context-status.md"
    tmp_json = json_path.with_suffix(".json.tmp")
    tmp_json.write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp_json, json_path)

    if latest:
        usage = latest.get("total_token_usage") or {}
        context_window = latest.get("context_window") or 0
        provider_context_window = latest.get("provider_raw_context_window") or 0
        context_used = int(latest.get("context_tokens_used") or 0)
        cumulative_used = int(latest.get("session_cumulative_tokens") or usage.get("total_tokens") or 0)
        remaining = latest.get("remaining_tokens")
        percent = latest.get("percent_used")
        lines = [
            "# Asclepius Context Status",
            "",
            f"- Generated: {generated_at}",
            "- Source: Hermes Agent provider usage logs + isolated Codex rollout token_count events",
            "- Reader rule: answer Asclepius context questions from this file, not by reconstructing raw logs.",
            "- Freshness: reflects the last completed Hermes turn; a currently in-flight turn appears after completion.",
            "",
            "## Latest Thread",
            "",
            f"- Thread: {latest.get('thread_id') or 'unknown'}",
            f"- Title: {latest.get('title') or 'unknown'}",
            f"- Model provider: {latest.get('model_provider') or 'unknown'}",
            f"- Model: {latest.get('model') or 'unknown'}",
            f"- Hermes session: {latest.get('hermes_session_id') or 'unknown'}",
            f"- Usage source: {latest.get('usage_source') or 'unknown'}",
            f"- Codex usable context window: {context_window:,} tokens" if context_window else "- Codex usable context window: unknown",
            f"- Provider raw context window: {provider_context_window:,} tokens" if provider_context_window else "- Provider raw context window: unknown",
            f"- Context tokens used: {context_used:,}",
            f"- Tokens remaining: {int(remaining):,}" if remaining is not None else "- Tokens remaining: unknown",
            f"- Percent used: {percent}%" if percent is not None else "- Percent used: unknown",
            f"- Session cumulative tokens: {cumulative_used:,}",
            "",
            "## Last Token Usage",
            "",
            f"- Input/context tokens: {int((latest.get('last_token_usage') or {}).get('input_tokens') or 0):,}",
            f"- Cached input tokens: {int((latest.get('last_token_usage') or {}).get('cached_input_tokens') or 0):,}",
            f"- Output tokens: {int((latest.get('last_token_usage') or {}).get('output_tokens') or 0):,}",
            f"- Reasoning output tokens: {int((latest.get('last_token_usage') or {}).get('reasoning_output_tokens') or 0):,}",
        ]
        tool_activity = latest.get("tool_activity") or {}
        tool_events_md = tool_activity.get("events") or []
        lines.extend([
            "",
            "## Hermes Tool Activity",
            "",
            f"- Tool events: {int(tool_activity.get('total_tool_events') or 0):,}",
            f"- Tool errors: {int(tool_activity.get('error_tool_events') or 0):,}",
        ])
        for event in tool_events_md[-10:]:
            detail = f" ({event.get('detail')})" if event.get("detail") else ""
            chars = event.get("output_chars")
            chars_text = f", {int(chars):,} chars" if chars is not None else ""
            lines.append(
                f"- {event.get('tool')}: {event.get('status')} in {event.get('duration')}{chars_text}{detail}"
            )
    else:
        lines = [
            "# Asclepius Context Status",
            "",
            f"- Generated: {generated_at}",
            "- No completed Asclepius token usage has been recorded yet.",
        ]
    tmp_md = md_path.with_suffix(".md.tmp")
    tmp_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp_md, md_path)


def scan_once(root: Path, distro: str) -> dict[str, int]:
    codex_home = root / "codex-home"
    sessions_dir = codex_home / "sessions"
    if not sessions_dir.exists():
        return {"rollouts_changed": 0, "threads_changed": 0}

    log_path = hermes_log_path(distro)
    calls = read_api_calls(log_path)
    tool_events = read_tool_events(log_path)
    totals: dict[str, int] = {}
    contexts: list[dict[str, Any]] = []
    rollouts_changed = 0
    for path in sessions_dir.rglob("*.jsonl"):
        changed, total = backfill_rollout(path, calls)
        if changed:
            rollouts_changed += 1
        if total is not None:
            totals[str(path)] = total
        context = latest_rollout_context(path)
        if context is not None:
            contexts.append(context)
    threads_changed = sync_threads_db(codex_home, totals)
    write_context_status(root, contexts, codex_home, tool_events)
    return {"rollouts_changed": rollouts_changed, "threads_changed": threads_changed}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(Path.home() / ".codex-nous-cloud"))
    parser.add_argument("--distro", default=os.environ.get("CODEX_HERMES_WSL_DISTRO", "Ubuntu"))
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--interval", type=float, default=4.0)
    parser.add_argument("--hash", default="", help=argparse.SUPPRESS)
    args = parser.parse_args()

    root = Path(args.root)
    while True:
        result = scan_once(root, args.distro)
        print(json.dumps(result, separators=(",", ":")), flush=True)
        if not args.watch:
            return 0
        time.sleep(max(1.0, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
