"""Per-agent disk session discovery (parity with Agent Sessions UI indexers)."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

RowDict = dict[str, Any]

_PREVIEW_LINES = 40
_CODEX_ROLLOUT = re.compile(r"rollout-.*\.jsonl$", re.I)
_GEMINI_SESSION = re.compile(r"^session-.*\.(json|jsonl)$", re.I)
_UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I
)


def path_matches_project(cwd: Optional[str], root: Path, repo_label: str) -> bool:
    if not cwd:
        return False
    root_str = str(root)
    root_prefix = root_str + os.sep if not root_str.endswith(os.sep) else root_str
    if cwd == root_str or cwd.startswith(root_prefix):
        return True
    if repo_label and repo_label.lower() in cwd.lower():
        return True
    return False


def _format_ts(ts: int) -> tuple[str, int]:
    if ts <= 0:
        return "—", 0
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S"), ts


def _mtime_ts(path: Path) -> int:
    try:
        return int(path.stat().st_mtime)
    except OSError:
        return 0


def _make_row(
    *,
    source: str,
    session_id: str,
    title: str,
    sort_ts: int,
    cwd: Optional[str],
    repo_label: str,
    model: Optional[str] = None,
    messages: int = 0,
    codex_internal_session_id: Optional[str] = None,
) -> RowDict:
    modified, sort_ts = _format_ts(sort_ts)
    return {
        "source": source,
        "session_id": session_id,
        "title": title or "(no title)",
        "modified": modified,
        "sort_ts": sort_ts,
        "cwd": cwd,
        "repo": repo_label,
        "model": model,
        "messages": messages,
        "codex_internal_session_id": codex_internal_session_id,
        "origin": "disk",
    }


def _iter_jsonl(path: Path, max_lines: int = _PREVIEW_LINES):
    try:
        with path.open(encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                line = line.strip()
                if line:
                    yield line
    except OSError:
        return


def _parse_json_line(line: str) -> Optional[dict]:
    try:
        obj = json.loads(line)
        return obj if isinstance(obj, dict) else None
    except json.JSONDecodeError:
        return None


def _extract_timestamp(obj: dict) -> int:
    for key in ("timestamp", "time", "ts", "created", "created_at", "datetime", "date"):
        val = obj.get(key)
        if val is None and isinstance(obj.get("payload"), dict):
            val = obj["payload"].get(key)
        if isinstance(val, (int, float)):
            v = float(val)
            if v > 1e14:
                v /= 1_000_000
            elif v > 1e11:
                v /= 1_000
            return int(v)
        if isinstance(val, str):
            try:
                return int(datetime.fromisoformat(val.replace("Z", "+00:00")).timestamp())
            except ValueError:
                pass
    return 0


def _first_claude_title(events: list[dict]) -> Optional[str]:
    skip = (
        "you are an expert",
        "you are a helpful",
        "act as a",
        "<command-name>",
        "caveat:",
        "<local-command",
    )
    for event in events:
        if event.get("type") != "user" or event.get("isMeta"):
            continue
        text = None
        msg = event.get("message")
        if isinstance(msg, dict):
            content = msg.get("content")
            if isinstance(content, list):
                text = " ".join(
                    str(item.get("text", "")) if isinstance(item, dict) else str(item)
                    for item in content
                )
            else:
                text = content
        if not text:
            text = event.get("content") or event.get("text")
        if isinstance(text, str) and text.strip():
            t = " ".join(text.strip().split())
            if len(t) > 200:
                t = t[:200]
            lower = t.lower()
            if not any(p in lower for p in skip):
                return t
    return None


def _cursor_cwd_from_path(path: Path) -> Optional[str]:
    parts = path.parts
    try:
        idx = parts.index("projects")
    except ValueError:
        return None
    if idx + 1 >= len(parts):
        return None
    project_name = parts[idx + 1]
    segments = project_name.split("-")
    if not segments:
        return None
    resolved = ""
    component = segments[0]
    for seg in segments[1:]:
        candidate = f"/{component}" if not resolved else f"{resolved}/{component}"
        if os.path.isdir(candidate):
            resolved = candidate
            component = seg
        else:
            component = f"{component}-{seg}"
    final = f"/{component}" if not resolved else f"{resolved}/{component}"
    if os.path.isdir(final):
        return final
    naive = "/" + project_name.replace("-", "/")
    return naive if os.path.isdir(naive) else None


def fetch_codex_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    sessions_root = Path.home() / ".codex" / "sessions"
    if not sessions_root.is_dir():
        return []
    rows: list[RowDict] = []
    for path in sessions_root.rglob("*.jsonl"):
        if not _CODEX_ROLLOUT.search(path.name):
            continue
        cwd = None
        internal_id = None
        model = None
        event_count = 0
        for line in _iter_jsonl(path):
            event_count += 1
            obj = _parse_json_line(line)
            if not obj:
                continue
            if not internal_id:
                internal_id = obj.get("session_id") or obj.get("id")
            if not cwd:
                cwd = obj.get("cwd")
                if not cwd and isinstance(obj.get("payload"), dict):
                    cwd = obj["payload"].get("cwd")
            if not model:
                model = obj.get("model")
        # Codex rollout filenames embed the internal session uuid, which is what
        # index.db stores as codex_internal_session_id. Extract the full uuid so
        # disk rows dedup against index rows (index session_id is a content hash).
        stem = path.stem
        name_uuid = _UUID.search(stem)
        if not internal_id and name_uuid:
            internal_id = name_uuid.group(0)
        file_id = name_uuid.group(0) if name_uuid else (stem.split("-")[-1] if "-" in stem else stem)
        session_id = internal_id or file_id
        sort_ts = _mtime_ts(path)
        if not path_matches_project(cwd, root, repo_label):
            continue
        rows.append(
            _make_row(
                source="codex",
                session_id=session_id,
                title=path.name,
                sort_ts=sort_ts,
                cwd=cwd,
                repo_label=repo_label,
                model=model,
                messages=event_count,
                codex_internal_session_id=internal_id,
            )
        )
        if limit and len(rows) >= int(limit):
            break
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_claude_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    roots = [Path.home() / ".claude", Path.home() / "claude-logs"]
    rows: list[RowDict] = []
    for base in roots:
        if not base.is_dir():
            continue
        for path in base.rglob("*.jsonl"):
            if path.suffix.lower() not in (".jsonl",):
                continue
            events: list[dict] = []
            session_id = None
            cwd = None
            model = None
            start_ts = 0
            end_ts = 0
            for line in _iter_jsonl(path, 50):
                obj = _parse_json_line(line)
                if not obj:
                    continue
                events.append(obj)
                if not session_id:
                    session_id = obj.get("session_id") or obj.get("id")
                if not cwd:
                    cwd = obj.get("cwd")
                    if not cwd and isinstance(obj.get("payload"), dict):
                        cwd = obj["payload"].get("cwd")
                if not model:
                    model = obj.get("model")
                ts = _extract_timestamp(obj)
                if ts:
                    start_ts = ts if not start_ts else min(start_ts, ts)
                    end_ts = max(end_ts, ts)
            if not session_id:
                session_id = path.stem[:36]
            if not path_matches_project(cwd, root, repo_label):
                continue
            title = _first_claude_title(events) or "(no title)"
            sort_ts = end_ts or start_ts or _mtime_ts(path)
            rows.append(
                _make_row(
                    source="claude",
                    session_id=session_id,
                    title=title,
                    sort_ts=sort_ts,
                    cwd=cwd,
                    repo_label=repo_label,
                    model=model,
                    messages=len(events),
                )
            )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_opencode_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    db_path = Path.home() / ".local/share/opencode/opencode.db"
    if not db_path.is_file():
        return []
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows: list[RowDict] = []
    try:
        sql = """
            SELECT id, title, directory, time_updated,
                   (SELECT COUNT(*) FROM message WHERE session_id = session.id)
            FROM session
            WHERE time_archived IS NULL
            ORDER BY time_updated DESC
        """
        for sid, title, directory, time_updated, msg_count in conn.execute(sql):
            if not path_matches_project(directory, root, repo_label):
                continue
            ts = int(time_updated / 1000) if time_updated and time_updated > 1e12 else int(time_updated or 0)
            rows.append(
                _make_row(
                    source="opencode",
                    session_id=sid,
                    title=(title or "").strip() or "(no title)",
                    sort_ts=ts,
                    cwd=directory,
                    repo_label=repo_label,
                    messages=int(msg_count or 0),
                )
            )
            if limit and len(rows) >= int(limit):
                break
    finally:
        conn.close()
    return rows


def _pi_read_header(path: Path) -> Optional[dict]:
    for line in _iter_jsonl(path, 5):
        obj = _parse_json_line(line)
        if obj and obj.get("type") == "session":
            return obj
    return None


def grok_sessions_root() -> Path:
    """Resolve Grok sessions root, honoring GROK_HOME like GrokSessionDiscovery."""
    raw = os.environ.get("GROK_HOME", "").strip()
    if raw:
        expanded = Path(raw).expanduser()
        candidates = [expanded / "sessions", expanded]
        for candidate in candidates:
            if candidate.is_dir():
                return candidate
        return expanded / "sessions"
    return Path.home() / ".grok" / "sessions"


def _decode_grok_project_dir(name: str) -> Optional[str]:
    try:
        from urllib.parse import unquote

        decoded = unquote(name).strip()
        return decoded or None
    except Exception:
        return None


def _grok_read_summary(session_dir: Path) -> Optional[dict]:
    summary_path = session_dir / "summary.json"
    if not summary_path.is_file():
        return None
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def fetch_grok_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    sessions_root = grok_sessions_root()
    if not sessions_root.is_dir():
        return []
    rows: list[RowDict] = []
    for project_dir in sessions_root.iterdir():
        if not project_dir.is_dir() or "%" not in project_dir.name:
            continue
        cwd = _decode_grok_project_dir(project_dir.name)
        if not path_matches_project(cwd, root, repo_label):
            continue
        for session_dir in project_dir.iterdir():
            if not session_dir.is_dir():
                continue
            chat_history = session_dir / "chat_history.jsonl"
            if not chat_history.is_file():
                continue
            summary = _grok_read_summary(session_dir) or {}
            info = summary.get("info") if isinstance(summary.get("info"), dict) else {}
            sid = info.get("id") or session_dir.name
            cwd = info.get("cwd") or cwd
            title = (
                summary.get("generated_title")
                or summary.get("session_summary")
                or f"Grok session {str(sid)[:12]}"
            )
            sort_ts = _mtime_ts(chat_history)
            updated = summary.get("updated_at") or summary.get("last_active_at")
            if isinstance(updated, str):
                try:
                    sort_ts = int(datetime.fromisoformat(updated.replace("Z", "+00:00")).timestamp())
                except ValueError:
                    pass
            rows.append(
                _make_row(
                    source="grok",
                    session_id=str(sid),
                    title=str(title).strip() or "(no title)",
                    sort_ts=sort_ts,
                    cwd=cwd,
                    repo_label=repo_label,
                    model=summary.get("current_model_id"),
                    messages=int(summary.get("num_chat_messages") or summary.get("num_messages") or 0),
                )
            )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def amp_sessions_root() -> Path:
    return Path.home() / ".local" / "share" / "amp" / "threads"


def antigravity_sessions_root() -> Path:
    return Path.home() / ".gemini" / "antigravity-cli"


def _amp_read_thread(path: Path) -> Optional[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def fetch_amp_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    sessions_root = amp_sessions_root()
    if not sessions_root.is_dir():
        return []
    rows: list[RowDict] = []
    for path in sessions_root.glob("T-*.json"):
        payload = _amp_read_thread(path)
        if not payload:
            continue
        sid = payload.get("id") or path.stem
        cwd = payload.get("cwd")
        if isinstance(cwd, dict):
            cwd = cwd.get("path") or cwd.get("root")
        if not path_matches_project(cwd if isinstance(cwd, str) else None, root, repo_label):
            continue
        created = payload.get("created")
        sort_ts = _mtime_ts(path)
        if isinstance(created, (int, float)):
            sort_ts = int(float(created) / 1000.0) if float(created) > 1e12 else int(created)
        title = (
            payload.get("title")
            or payload.get("summary")
            or payload.get("name")
            or f"Amp thread {str(sid)[:12]}"
        )
        messages = payload.get("messages")
        msg_count = len(messages) if isinstance(messages, list) else 0
        rows.append(
            _make_row(
                source="amp",
                session_id=str(sid),
                title=str(title).strip() or "(no title)",
                sort_ts=sort_ts,
                cwd=cwd if isinstance(cwd, str) else None,
                repo_label=repo_label,
                messages=msg_count,
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_antigravity_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    history_path = antigravity_sessions_root() / "history.jsonl"
    if not history_path.is_file():
        return []
    latest_by_id: dict[str, RowDict] = {}
    fallback_mtime = _mtime_ts(history_path)
    for line in _iter_jsonl(history_path):
        obj = _parse_json_line(line)
        if not obj:
            continue
        sid = obj.get("conversationId") or obj.get("conversation_id") or obj.get("id")
        if not sid:
            continue
        cwd = obj.get("cwd") or obj.get("workingDirectory")
        if not path_matches_project(cwd if isinstance(cwd, str) else None, root, repo_label):
            continue
        sort_ts = _extract_timestamp(obj) or fallback_mtime
        title = (
            obj.get("title")
            or obj.get("summary")
            or obj.get("name")
            or f"Antigravity session {str(sid)[:12]}"
        )
        row = _make_row(
            source="antigravity",
            session_id=str(sid),
            title=str(title).strip() or "(no title)",
            sort_ts=sort_ts,
            cwd=cwd if isinstance(cwd, str) else None,
            repo_label=repo_label,
        )
        existing = latest_by_id.get(str(sid))
        if existing is None or row["sort_ts"] >= existing["sort_ts"]:
            latest_by_id[str(sid)] = row
    rows = list(latest_by_id.values())
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_pi_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    sessions_root = Path.home() / ".pi" / "agent" / "sessions"
    if not sessions_root.is_dir():
        return []
    rows: list[RowDict] = []
    for path in sessions_root.rglob("*.jsonl"):
        header = _pi_read_header(path)
        if not header:
            continue
        cwd = header.get("cwd")
        if not path_matches_project(cwd, root, repo_label):
            continue
        sid = header.get("id") or path.stem
        ts_raw = header.get("timestamp")
        sort_ts = 0
        if isinstance(ts_raw, str):
            try:
                sort_ts = int(datetime.fromisoformat(ts_raw.replace("Z", "+00:00")).timestamp())
            except ValueError:
                sort_ts = _mtime_ts(path)
        else:
            sort_ts = _mtime_ts(path)
        title = (header.get("summary") or header.get("name") or path.parent.name or "").strip() or "(no title)"
        rows.append(
            _make_row(
                source="pi",
                session_id=sid,
                title=title,
                sort_ts=sort_ts,
                cwd=cwd,
                repo_label=repo_label,
                model=header.get("modelId"),
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_gemini_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    base = Path.home() / ".gemini" / "tmp"
    if not base.is_dir():
        return []
    rows: list[RowDict] = []
    for path in base.rglob("*"):
        if not path.is_file() or not _GEMINI_SESSION.match(path.name):
            continue
        cwd = None
        title = None
        model = None
        session_id = None
        sort_ts = _mtime_ts(path)
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
            data: Any
            if path.suffix.lower() == ".jsonl":
                data = None
                for line in raw.splitlines()[:_PREVIEW_LINES]:
                    obj = _parse_json_line(line.strip())
                    if obj:
                        data = obj
                        break
                if data is None:
                    continue
            else:
                data = json.loads(raw)
            if isinstance(data, list):
                items = data
                meta = {}
            elif isinstance(data, dict):
                items = data.get("messages") or data.get("history") or []
                meta = data
                session_id = data.get("sessionId") or data.get("session_id")
            else:
                continue
            if not session_id:
                session_id = meta.get("sessionId") if isinstance(meta, dict) else None
            if not session_id:
                import hashlib

                session_id = hashlib.sha256(str(path).encode()).hexdigest()[:32]
            for key in ("lastUpdated", "last_updated"):
                if isinstance(meta, dict) and meta.get(key):
                    sort_ts = _extract_timestamp({"ts": meta[key]}) or sort_ts
            if isinstance(items, list):
                for item in items[:20]:
                    if not isinstance(item, dict):
                        continue
                    if not cwd:
                        for k in ("cwd", "workdir", "working_directory"):
                            v = item.get(k)
                            if isinstance(v, str) and v:
                                cwd = v
                                break
                    if not title and item.get("role") == "user":
                        t = item.get("text") or item.get("content")
                        if isinstance(t, str) and t.strip():
                            title = t.strip()[:200]
        except (OSError, json.JSONDecodeError):
            continue
        if not path_matches_project(cwd, root, repo_label):
            continue
        rows.append(
            _make_row(
                source="gemini",
                session_id=session_id,
                title=title or "(no title)",
                sort_ts=sort_ts,
                cwd=cwd,
                repo_label=repo_label,
                model=model,
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_hermes_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    sessions_root = Path.home() / ".hermes" / "sessions"
    if not sessions_root.is_dir():
        return []
    rows: list[RowDict] = []
    for path in sessions_root.glob("session_*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        sid = data.get("session_id") or path.stem
        cwd = data.get("cwd")
        if not cwd and isinstance(data.get("model_config"), dict):
            cwd = data["model_config"].get("cwd")
        if isinstance(cwd, str) and cwd.startswith("~"):
            cwd = os.path.expanduser(cwd)
        if not path_matches_project(cwd, root, repo_label):
            continue
        sort_ts = 0
        for key in ("last_updated", "session_start"):
            if data.get(key):
                sort_ts = max(sort_ts, _extract_timestamp({key: data[key]}))
        if not sort_ts:
            sort_ts = _mtime_ts(path)
        msgs = data.get("messages") or []
        title = data.get("platform") or sid
        if isinstance(msgs, list) and msgs:
            for m in msgs:
                if isinstance(m, dict) and m.get("role") == "user":
                    t = m.get("content") or m.get("text")
                    if isinstance(t, str) and t.strip():
                        title = t.strip()[:200]
                        break
        rows.append(
            _make_row(
                source="hermes",
                session_id=sid,
                title=str(title),
                sort_ts=sort_ts,
                cwd=cwd,
                repo_label=repo_label,
                model=data.get("model"),
                messages=len(msgs) if isinstance(msgs, list) else 0,
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_copilot_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    base = Path.home() / ".copilot" / "session-state"
    if not base.is_dir():
        return []
    rows: list[RowDict] = []
    for path in base.rglob("*.jsonl"):
        cwd = None
        session_id = path.stem
        title = None
        event_count = 0
        for line in _iter_jsonl(path):
            event_count += 1
            obj = _parse_json_line(line)
            if not obj:
                continue
            if obj.get("type") == "session.info":
                msg = obj.get("message") if isinstance(obj.get("message"), dict) else obj
                trust = msg.get("folderTrust") if isinstance(msg, dict) else None
                if isinstance(trust, dict):
                    cwd = trust.get("path") or trust.get("cwd")
            if not title and obj.get("type") == "user":
                t = obj.get("content") or obj.get("text")
                if isinstance(t, str) and t.strip():
                    title = t.strip()[:200]
        if not path_matches_project(cwd, root, repo_label):
            continue
        rows.append(
            _make_row(
                source="copilot",
                session_id=session_id,
                title=title or "(no title)",
                sort_ts=_mtime_ts(path),
                cwd=cwd,
                repo_label=repo_label,
                messages=event_count,
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_droid_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    bases = [
        Path.home() / ".factory" / "sessions",
        Path.home() / ".factory" / "projects",
    ]
    rows: list[RowDict] = []
    seen: set[str] = set()
    for base in bases:
        if not base.is_dir():
            continue
        for path in base.rglob("*.jsonl"):
            key = str(path)
            if key in seen:
                continue
            seen.add(key)
            cwd = None
            session_id = path.stem
            title = None
            event_count = 0
            for line in _iter_jsonl(path):
                event_count += 1
                obj = _parse_json_line(line)
                if not obj:
                    continue
                obj_type = str(obj.get("type") or "").replace("_", "").replace("-", "").lower()
                if obj_type == "sessionstart":
                    session_id = str(obj.get("id") or session_id)
                    for key in ("title", "sessionTitle", "session_title"):
                        candidate = obj.get(key)
                        if isinstance(candidate, str) and candidate.strip():
                            title = candidate.strip()[:200]
                            break
                if not cwd:
                    for k in ("cwd", "workdir", "working_directory", "workspace"):
                        v = obj.get(k)
                        if isinstance(v, str) and v:
                            cwd = v
                            break
                if not title and obj.get("role") == "user":
                    t = obj.get("content") or obj.get("text")
                    if isinstance(t, str) and t.strip():
                        title = t.strip()[:200]
                if not title and obj_type == "message":
                    msg = obj.get("message")
                    if isinstance(msg, dict) and msg.get("role") == "user":
                        content = msg.get("content")
                        if isinstance(content, list):
                            for part in content:
                                if not isinstance(part, dict):
                                    continue
                                if part.get("type") == "text":
                                    t = part.get("text")
                                    if isinstance(t, str) and t.strip() and "<system-reminder>" not in t[:80].lower():
                                        title = t.strip()[:200]
                                        break
            parent_cwd = str(path.parent)
            if not cwd and path_matches_project(parent_cwd, root, repo_label):
                cwd = parent_cwd
            if not path_matches_project(cwd, root, repo_label):
                continue
            rows.append(
                _make_row(
                    source="droid",
                    session_id=session_id,
                    title=title or "(no title)",
                    sort_ts=_mtime_ts(path),
                    cwd=cwd,
                    repo_label=repo_label,
                    messages=event_count,
                )
            )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_openclaw_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    roots = [Path.home() / ".openclaw", Path.home() / ".clawdbot"]
    rows: list[RowDict] = []
    for state_root in roots:
        agents_dir = state_root / "agents"
        if not agents_dir.is_dir():
            continue
        for path in agents_dir.rglob("*.jsonl"):
            if ".jsonl.deleted." in path.name:
                continue
            session_id = path.stem.split(".jsonl")[0]
            cwd = None
            title = None
            event_count = 0
            for line in _iter_jsonl(path):
                event_count += 1
                obj = _parse_json_line(line)
                if not obj:
                    continue
                if not cwd:
                    for k in ("cwd", "workdir", "working_directory"):
                        v = obj.get(k)
                        if isinstance(v, str) and v:
                            cwd = v
                            break
                if not title:
                    t = obj.get("text") or obj.get("content")
                    if isinstance(t, str) and "user" in str(obj.get("role", "")).lower():
                        title = t.strip()[:200]
            if not path_matches_project(cwd, root, repo_label):
                continue
            rows.append(
                _make_row(
                    source="openclaw",
                    session_id=session_id,
                    title=title or "(no title)",
                    sort_ts=_mtime_ts(path),
                    cwd=cwd,
                    repo_label=repo_label,
                    messages=event_count,
                )
            )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


def fetch_cursor_disk(root: Path, repo_label: str, limit: Optional[int]) -> list[RowDict]:
    projects = Path.home() / ".cursor" / "projects"
    if not projects.is_dir():
        return []
    rows: list[RowDict] = []
    for path in projects.rglob("*.jsonl"):
        if "/agent-transcripts/" not in path.as_posix():
            continue
        cwd = _cursor_cwd_from_path(path)
        if not path_matches_project(cwd, root, repo_label):
            continue
        session_id = path.parent.name if path.parent.name else path.stem
        title = None
        event_count = 0
        for line in _iter_jsonl(path):
            event_count += 1
            obj = _parse_json_line(line)
            if not obj:
                continue
            role = str(obj.get("role", "")).lower()
            if not title and role == "user":
                t = obj.get("text") or obj.get("content")
                if isinstance(t, str) and t.strip():
                    title = t.strip()[:200]
        rows.append(
            _make_row(
                source="cursor",
                session_id=session_id,
                title=title or "(no title)",
                sort_ts=_mtime_ts(path),
                cwd=cwd,
                repo_label=repo_label,
                messages=event_count,
            )
        )
    rows.sort(key=lambda r: r["sort_ts"], reverse=True)
    return rows[: int(limit)] if limit else rows


DISK_FETCHERS: dict[str, Callable[[Path, str, Optional[int]], list[RowDict]]] = {
    "codex": fetch_codex_disk,
    "claude": fetch_claude_disk,
    "gemini": fetch_gemini_disk,
    "opencode": fetch_opencode_disk,
    "hermes": fetch_hermes_disk,
    "copilot": fetch_copilot_disk,
    "droid": fetch_droid_disk,
    "openclaw": fetch_openclaw_disk,
    "cursor": fetch_cursor_disk,
    "pi": fetch_pi_disk,
    "grok": fetch_grok_disk,
    "amp": fetch_amp_disk,
    "antigravity": fetch_antigravity_disk,
}