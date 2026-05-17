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
from datetime import datetime
from pathlib import Path
from typing import Any


SESSION_RE = re.compile(r"HERMES_SESSION_ID=([0-9]{8}_[0-9]{6}_[0-9a-f]+)")
API_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(?P<ms>\d{3}) "
    r"INFO \[(?P<session>[^\]]+)\].*API call #(?P<call>\d+):"
    r".*?\bin=(?P<input>\d+)\s+out=(?P<output>\d+)\s+total=(?P<total>\d+)"
    r"(?:.*?\bcache=(?P<cache_read>\d+)/(?P<cache_prompt>\d+))?"
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


def scan_once(root: Path, distro: str) -> dict[str, int]:
    codex_home = root / "codex-home"
    sessions_dir = codex_home / "sessions"
    if not sessions_dir.exists():
        return {"rollouts_changed": 0, "threads_changed": 0}

    calls = read_api_calls(hermes_log_path(distro))
    totals: dict[str, int] = {}
    rollouts_changed = 0
    for path in sessions_dir.rglob("*.jsonl"):
        changed, total = backfill_rollout(path, calls)
        if changed:
            rollouts_changed += 1
        if total is not None:
            totals[str(path)] = total
    threads_changed = sync_threads_db(codex_home, totals)
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
