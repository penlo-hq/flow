"""
pipeline.py
===========

Penlo local data-ingestion pipeline — full implementation.

End-to-end flow for every transcript:

    transcripts/*.txt
        |  (read + resolve real capture time)
        v
    [Anthropic Claude API]  -> raw JSON text
        |  (strip fences, json.loads)
        v
    raw dict  -> assemble + STRICT Pydantic validation (Penlo Contract v1.1)
        |
        +-- validation/extraction error --> failed/<name>.txt
        |                                   failed/<name>.error.txt   (stack trace)
        |
        v
    PenloPayload  -> output/<name>_payload.json   (pretty JSON, always written on validation success)
        |
        v
    [Network sync -> Enterprise Brain]
        |
        +-- 200 OK            --> move transcript to processed/   (SYNCED)
        +-- 429 rate limited  --> exponential backoff 60s/120s/300s, then queue if still failing
        +-- 5xx / network     --> payload buffered in queue/, transcript to processed/ (QUEUED)
        +-- 401/403 auth       --> payload buffered in queue/, critical log (QUEUED)

Milestones implemented:
    M1  Automated watchdog file watcher (`--watch`) with write-completion debounce.
    M2  Real capture-time resolution from filename (YYYYMMDD_HHMMSS_*) or mtime fallback.
    M3  Resilient HTTP syncer with status handling + mandatory exponential backoff.
    M4  Local archive/recovery state machine: processed/ + output/ + failed/(+log) + queue/.

Usage:
    python pipeline.py                 # process existing transcripts once, then drain queue
    python pipeline.py --watch         # do the above, then watch transcripts/ forever
    python pipeline.py --retry-queue   # only attempt to drain the offline queue/
    python pipeline.py --no-sync       # local-only: extract + validate + queue, never call network
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import requests
from dotenv import load_dotenv
from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer

from anthropic import Anthropic

from schema import Fact, PenloPayload

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# Project-root-relative workspace directories.
BASE_DIR = Path(__file__).resolve().parent
TRANSCRIPTS_DIR = BASE_DIR / "transcripts"   # INPUT
OUTPUT_DIR = BASE_DIR / "output"             # validated payloads
PROCESSED_DIR = BASE_DIR / "processed"       # raw transcripts that succeeded
FAILED_DIR = BASE_DIR / "failed"             # transcripts that failed + error logs
QUEUE_DIR = BASE_DIR / "queue"               # offline buffer for payloads pending sync

ALL_DIRS = (TRANSCRIPTS_DIR, OUTPUT_DIR, PROCESSED_DIR, FAILED_DIR, QUEUE_DIR)

# Anthropic model + generation settings.
# NOTE: The Anthropic API requires fully-qualified, dated model IDs. The two
# values below correspond to the "claude-3-5-sonnet" and "claude-3-opus"
# families requested in the spec. Swap MODEL_NAME to ALT_MODEL_NAME if desired.
MODEL_NAME = "claude-3-5-sonnet-20241022"
ALT_MODEL_NAME = "claude-3-opus-20240229"  # noqa: F841  (kept for easy switching)
MAX_TOKENS = 4000
TEMPERATURE = 0.0  # Deterministic, strict factual extraction.

# Enterprise Brain ingestion endpoint (Milestone 3).
# Override via PENLO_BRAIN_INGEST_URL in .env (see .env.example).
ENTERPRISE_BRAIN_URL = os.environ.get(
    "PENLO_BRAIN_INGEST_URL",
    "http://localhost:8000/api/v1/ingest/penlo-brain",
)
HTTP_TIMEOUT_SECONDS = 15
# Mandatory exponential backoff schedule (seconds) applied on HTTP 429.
BACKOFF_SCHEDULE = (60, 120, 300)

# Placeholder sentinels shipped in .env — treated as "not configured".
ANTHROPIC_PLACEHOLDER = "sk-ant-REPLACE_ME"
PENLO_PLACEHOLDER = "pb_live_REPLACE_ME"

# Filename convention for embedded capture time: 20260529_143000_meeting.txt
CAPTURE_FILENAME_FORMAT = "%Y%m%d_%H%M%S"

# The exact, optimized extraction system prompt embedded into the client call.
SYSTEM_PROMPT = """You are the central Extraction Engine for "Penlo," an Enterprise AI Brain. Your sole function is to process raw, messy, multi-speaker audio transcripts, strip out all conversational filler, and extract high-signal, structured intelligence. 

You will output ONLY a valid JSON object. Do not include markdown code blocks, conversational text, preambles, or explanations. 

# NON-NEGOTIABLE EXTRACTION RULES:
1. THE FACT TRIPLES (Subject, Predicate, Object):
- Subjects: MUST be proper nouns or well-formed noun phrases (e.g., "Sarah Chen", "Acme Corp", "API rate limiter"). NEVER use pronouns ("he", "they", "it") or vague references ("someone", "the team"). If a pronoun cannot be confidently resolved to a specific name in the context, skip the fact entirely.
- Predicates: MUST be short verb phrases in the present tense (e.g., "is working on", "decided", "owns", "mentioned", "blocked by"). Do not use complex past-tense narratives.
- Objects: Keep them concise and specific.

2. CONFIDENCE SCORING (0.60 to 0.85):
- Because you are processing an AI-generated transcript, your confidence score for any fact MUST strictly fall between 0.60 and 0.85. 
- NEVER use 1.0. 
- Use 0.80 - 0.85 for clearly stated, unambiguous facts.
- Use 0.60 - 0.70 for implied facts, or facts where the exact wording was messy.

3. UNKNOWN SPEAKERS & DIARIZATION:
- If a speaker states a fact ("I am working on the dashboard") but their identity is unknown, the subject MUST be "Unknown Speaker [Number]". 
- Drop the confidence score for "Unknown Speaker" facts closer to 0.60. Do not guess the speaker's identity.

4. THE 11 ONTOLOGY NODE TYPES:
Any extracted entity or concept must conceptually map to one of these 11 types: `person`, `topic`, `task`, `decision`, `feature`, `client`, `event`, `draft`, `team`, `company`, `agent`. When generating the "topicSummary" array, ensure the strings align with these categories.

5. PEOPLE EXTRACTION:
- Extract all specific humans mentioned or speaking. 
- If an email or phone number is mentioned, include it. Otherwise, return null. 
- Keep notes extremely brief (under 10 words).

# REQUIRED JSON SCHEMA STRUCTURE TO RETURN:
{
  "facts": [
    {"subject": "<Proper Noun>", "predicate": "<Short present-tense verb phrase>", "object": "<Concise detail>", "confidence": <Float 0.60 - 0.85>}
  ],
  "people": [
    {"name": "<String>", "email": "<String or null>", "phone": "<String or null>", "notes": "<String or null>"}
  ],
  "topicSummary": ["<String>"]
}
"""


# ---------------------------------------------------------------------------
# Runtime configuration container
# ---------------------------------------------------------------------------

@dataclass
class Config:
    """Resolved runtime configuration assembled from the environment."""

    client: Anthropic
    penlo_api_key: Optional[str]
    user_email: Optional[str]
    sync_enabled: bool  # False when key missing/placeholder OR --no-sync passed.


# ---------------------------------------------------------------------------
# Environment initialization
# ---------------------------------------------------------------------------

def init_config(force_no_sync: bool = False) -> Config:
    """Load ``.env`` and build a :class:`Config`.

    Raises:
        RuntimeError: If ``ANTHROPIC_API_KEY`` is missing or still a placeholder.
    """
    load_dotenv()  # Pull variables from local .env into os.environ.

    anthropic_key = (os.getenv("ANTHROPIC_API_KEY") or "").strip()
    if not anthropic_key or anthropic_key == ANTHROPIC_PLACEHOLDER:
        raise RuntimeError(
            "ANTHROPIC_API_KEY is not set (or still the placeholder). Edit .env and set:\n\n"
            "    ANTHROPIC_API_KEY=sk-ant-...\n"
        )

    client = Anthropic(api_key=anthropic_key)

    penlo_key = (os.getenv("PENLO_API_KEY") or "").strip() or None
    user_email = (os.getenv("PENLO_USER_EMAIL") or "").strip() or None

    penlo_configured = bool(penlo_key) and penlo_key != PENLO_PLACEHOLDER
    sync_enabled = penlo_configured and not force_no_sync

    if force_no_sync:
        print("[CONFIG] Network sync disabled via --no-sync. Payloads will be queued locally.")
    elif not penlo_configured:
        print(
            "[CONFIG] PENLO_API_KEY not configured (placeholder/missing). "
            "Network sync disabled; payloads will be buffered in ./queue/ for later retry."
        )

    return Config(
        client=client,
        penlo_api_key=penlo_key,
        user_email=user_email,
        sync_enabled=sync_enabled,
    )


def ensure_workspace_dirs() -> None:
    """Create all five workspace directories if they do not already exist."""
    for directory in ALL_DIRS:
        directory.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

def utc_now_iso() -> str:
    """Return the current UTC time as an ISO 8601 string."""
    return datetime.now(timezone.utc).isoformat()


def get_actual_capture_time(file_path: str | Path) -> str:
    """Resolve the real-world capture time for a transcript (Milestone 2).

    Strategy:
        Option A — parse a structured filename prefix ``YYYYMMDD_HHMMSS_*`` and
                   interpret it as UTC (e.g. ``20260529_143000_meeting.txt``).
        Option B — fall back to the file's modification time, converted to UTC.

    Args:
        file_path: Path to the transcript file.

    Returns:
        An ISO 8601 UTC timestamp string.
    """
    path = Path(file_path)
    filename = path.name

    # Option A: structured filename prefix -> "YYYYMMDD_HHMMSS".
    parts = filename.split("_")
    if len(parts) >= 2 and parts[0].isdigit() and len(parts[0]) == 8 and parts[1][:6].isdigit():
        stamp = f"{parts[0]}_{parts[1][:6]}"
        try:
            parsed = datetime.strptime(stamp, CAPTURE_FILENAME_FORMAT)
            return parsed.replace(tzinfo=timezone.utc).isoformat()
        except ValueError:
            pass  # Malformed prefix — fall through to mtime.

    # Option B fallback: filesystem modification time, converted to UTC.
    try:
        mtime = os.path.getmtime(path)
        return datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
    except OSError:
        # Last-resort fallback so we always return a valid timestamp.
        return utc_now_iso()


def strip_markdown_fences(text: str) -> str:
    """Remove accidental ```json ... ``` fences the model may emit.

    Returns the inner JSON text, trimmed of leading/trailing whitespace.
    """
    cleaned = text.strip()
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        cleaned = "\n".join(lines).strip()
    return cleaned


def wait_for_file_stable(
    path: Path,
    stable_checks: int = 3,
    interval: float = 0.4,
    timeout: float = 30.0,
) -> bool:
    """Block until a file's size stops changing (i.e. the writer has finished).

    watchdog fires ``on_created`` the instant a file appears, which can be before
    the OS finishes writing it. We poll the size until it is stable across
    ``stable_checks`` consecutive reads.

    Returns:
        True if the file settled, False if it vanished or timed out.
    """
    deadline = time.monotonic() + timeout
    last_size = -1
    streak = 0
    while time.monotonic() < deadline:
        try:
            size = path.stat().st_size
        except OSError:
            return False  # File disappeared mid-write.
        if size == last_size:
            streak += 1
            if streak >= stable_checks:
                return True
        else:
            streak = 0
            last_size = size
        time.sleep(interval)
    return False


# ---------------------------------------------------------------------------
# LLM extraction core
# ---------------------------------------------------------------------------

def extract_intelligence_from_transcript(
    client: Anthropic, transcript_text: str
) -> Dict[str, Any]:
    """Send a transcript to Claude and return the parsed JSON dictionary.

    Raises:
        ValueError: If the response is empty or cannot be parsed as JSON.
        anthropic.APIError: Propagated from the SDK on transport/API failures.
    """
    response = client.messages.create(
        model=MODEL_NAME,
        max_tokens=MAX_TOKENS,
        temperature=TEMPERATURE,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": (
                    "Extract structured intelligence from the following transcript. "
                    "Return ONLY the JSON object.\n\n"
                    f"# TRANSCRIPT:\n{transcript_text}"
                ),
            }
        ],
    )

    # Concatenate all returned text blocks (Claude returns a list of blocks).
    raw_text = "".join(
        block.text for block in response.content if getattr(block, "type", None) == "text"
    )

    if not raw_text.strip():
        raise ValueError("The model returned an empty response.")

    cleaned = strip_markdown_fences(raw_text)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"Failed to parse model output as JSON: {exc}\n--- RAW OUTPUT ---\n{raw_text}"
        ) from exc


# ---------------------------------------------------------------------------
# Payload assembly
# ---------------------------------------------------------------------------

def assemble_payload(
    raw: Dict[str, Any],
    capture_time: str,
    user_email: Optional[str] = None,
) -> PenloPayload:
    """Map a raw LLM dict into a validated :class:`PenloPayload`.

    - ``syncedAt`` is stamped with the processing moment (now).
    - Every ``Fact.capturedAt`` is stamped with the real-world ``capture_time``
      (Milestone 2) so the graph DB's TTL/decay engines use audio time, not
      server time.

    Raises:
        pydantic.ValidationError: If the data violates the v1.1 contract.
    """
    synced_at = utc_now_iso()

    facts = []
    for raw_fact in raw.get("facts", []) or []:
        fact_data = dict(raw_fact)  # Defensive copy.
        fact_data["capturedAt"] = capture_time
        facts.append(Fact(**fact_data))

    payload_kwargs: Dict[str, Any] = {
        "syncedAt": synced_at,
        "facts": facts,
        "people": raw.get("people", []) or [],
        "topicSummary": raw.get("topicSummary", []) or [],
    }
    if user_email is not None:
        payload_kwargs["userEmail"] = user_email

    return PenloPayload(**payload_kwargs)


# ---------------------------------------------------------------------------
# Network syncer (Milestone 3)
# ---------------------------------------------------------------------------

@dataclass
class SyncResult:
    """Outcome of an attempt to sync a payload to the Enterprise Brain."""

    ok: bool
    status: str  # SUCCESS | RATE_LIMITED | AUTH_FAILED | SERVER_ERROR | NETWORK_ERROR | SKIPPED
    detail: str = ""


def sync_to_enterprise_brain(payload_dict: Dict[str, Any], api_key: str) -> SyncResult:
    """POST a single validated payload to the Enterprise Brain ingestion endpoint.

    Maps HTTP results into a structured :class:`SyncResult` (no exceptions escape).
    """
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": "Penlo-Brain/1.1",
    }

    try:
        response = requests.post(
            ENTERPRISE_BRAIN_URL,
            json=payload_dict,
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
    except requests.exceptions.RequestException as exc:
        # Timeout / DNS / connection reset -> recoverable, queue for local recovery.
        return SyncResult(False, "NETWORK_ERROR", f"Network error: {exc}")

    if response.status_code == 200:
        return SyncResult(True, "SUCCESS", "Backend accepted data asynchronously.")
    if response.status_code == 429:
        return SyncResult(False, "RATE_LIMITED", "HTTP 429 — rate limited.")
    if response.status_code in (401, 403):
        return SyncResult(
            False, "AUTH_FAILED", f"HTTP {response.status_code} — invalid pb_live key credential."
        )
    return SyncResult(
        False, "SERVER_ERROR", f"HTTP {response.status_code}: {response.text[:200]}"
    )


def sync_with_backoff(
    payload_dict: Dict[str, Any],
    api_key: str,
    schedule: tuple[int, ...] = BACKOFF_SCHEDULE,
    sleep_func=None,
) -> SyncResult:
    """Sync with the mandatory exponential backoff sequence on HTTP 429.

    On 429 we wait 60s -> 120s -> 300s between retries. All other non-success
    outcomes (network/server/auth) return immediately so the caller can buffer
    the payload in the offline queue rather than blocking.
    """
    # Resolve the sleeper at call time so tests can monkeypatch ``time.sleep``.
    sleep = sleep_func if sleep_func is not None else time.sleep

    result = sync_to_enterprise_brain(payload_dict, api_key)
    if result.status != "RATE_LIMITED":
        return result

    for delay in schedule:
        print(f"[BACKOFF]    Rate limited. Sleeping {delay}s before retry...")
        sleep(delay)
        result = sync_to_enterprise_brain(payload_dict, api_key)
        if result.status != "RATE_LIMITED":
            return result

    return result  # Still rate-limited after the full schedule.


# ---------------------------------------------------------------------------
# Persistence + archive/recovery state machine (Milestone 4)
# ---------------------------------------------------------------------------

def payload_filename(stem: str) -> str:
    """Canonical payload filename for a given transcript stem."""
    return f"{stem}_payload.json"


def write_output(payload: PenloPayload, stem: str) -> Path:
    """Write a validated payload to ``./output/`` with pretty indentation."""
    out_path = OUTPUT_DIR / payload_filename(stem)
    out_path.write_text(
        json.dumps(payload.model_dump(), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return out_path


def write_queue(payload_dict: Dict[str, Any], stem: str) -> Path:
    """Buffer a payload in ``./queue/`` for later retry (offline recovery)."""
    queue_path = QUEUE_DIR / payload_filename(stem)
    queue_path.write_text(
        json.dumps(payload_dict, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return queue_path


def remove_from_queue(stem: str) -> None:
    """Delete a buffered payload from ``./queue/`` once it has synced."""
    (QUEUE_DIR / payload_filename(stem)).unlink(missing_ok=True)


def move_to_processed(transcript_path: Path) -> None:
    """Archive a raw transcript to ``./processed/`` after successful handling."""
    if transcript_path.exists():
        shutil.move(str(transcript_path), str(PROCESSED_DIR / transcript_path.name))


def move_to_failed_with_log(transcript_path: Path, error_text: str) -> None:
    """Move a failing transcript to ``./failed/`` and write a sibling error log."""
    if transcript_path.exists():
        shutil.move(str(transcript_path), str(FAILED_DIR / transcript_path.name))
    log_path = FAILED_DIR / f"{transcript_path.stem}.error.txt"
    log_path.write_text(
        f"Failed at {utc_now_iso()}\nTranscript: {transcript_path.name}\n\n{error_text}",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Single-file processing (ties everything together)
# ---------------------------------------------------------------------------

def process_single_file(config: Config, transcript_path: Path) -> str:
    """Run the full extract -> validate -> persist -> sync -> archive flow.

    Returns a short status string: "SYNCED", "QUEUED", or "FAILED".
    """
    stem = transcript_path.stem
    print(f"\n[PROCESSING] {transcript_path.name}")

    # --- Phase 1: extraction + strict validation -------------------------------
    try:
        transcript_text = transcript_path.read_text(encoding="utf-8").strip()
        if not transcript_text:
            raise ValueError("Transcript file is empty.")

        capture_time = get_actual_capture_time(transcript_path)
        raw = extract_intelligence_from_transcript(config.client, transcript_text)
        payload = assemble_payload(raw, capture_time, user_email=config.user_email)
    except Exception:  # noqa: BLE001 - quarantine any extraction/validation failure.
        error_text = traceback.format_exc()
        print(f"[FAILED]     {transcript_path.name} — extraction/validation error:")
        print(error_text)
        move_to_failed_with_log(transcript_path, error_text)
        print(f"[ROUTED]     -> failed/{transcript_path.name} (+ .error.txt log)")
        return "FAILED"

    # --- Phase 2: persist the validated payload (always) -----------------------
    out_path = write_output(payload, stem)
    print(
        f"[VALIDATED]  {out_path.name} "
        f"({len(payload.facts)} facts, {len(payload.people)} people, "
        f"capturedAt={payload.facts[0].capturedAt if payload.facts else 'n/a'})"
    )
    payload_dict = payload.model_dump()

    # --- Phase 3: network sync + archive state machine -------------------------
    if config.sync_enabled and config.penlo_api_key:
        result = sync_with_backoff(payload_dict, config.penlo_api_key)
    else:
        result = SyncResult(False, "SKIPPED", "Sync disabled; buffering to queue.")

    if result.ok:
        remove_from_queue(stem)  # In case a stale buffered copy existed.
        move_to_processed(transcript_path)
        print(f"[SYNCED]     {transcript_path.name} -> processed/ (backend accepted).")
        return "SYNCED"

    # Any non-success: buffer payload for offline recovery, archive the transcript.
    write_queue(payload_dict, stem)
    move_to_processed(transcript_path)
    severity = "CRITICAL" if result.status == "AUTH_FAILED" else "QUEUED"
    print(f"[{severity}]     sync {result.status}: {result.detail}")
    print(f"[QUEUED]     payload buffered -> queue/{payload_filename(stem)} (will retry).")
    return "QUEUED"


# ---------------------------------------------------------------------------
# Offline queue drain (recovery)
# ---------------------------------------------------------------------------

def retry_queue(config: Config) -> None:
    """Attempt to sync every payload buffered in ``./queue/``.

    Successfully synced payloads are removed from the queue; the rest remain for
    the next attempt.
    """
    if not config.sync_enabled or not config.penlo_api_key:
        print("[QUEUE]      Sync disabled — skipping queue drain.")
        return

    queued = sorted(QUEUE_DIR.glob("*.json"))
    if not queued:
        print("[QUEUE]      Offline queue is empty. Nothing to retry.")
        return

    print(f"[QUEUE]      Draining {len(queued)} buffered payload(s)...")
    drained = 0
    for queue_path in queued:
        try:
            payload_dict = json.loads(queue_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"[QUEUE]      Skipping unreadable {queue_path.name}: {exc}")
            continue

        result = sync_with_backoff(payload_dict, config.penlo_api_key)
        if result.ok:
            queue_path.unlink(missing_ok=True)
            drained += 1
            print(f"[QUEUE]      Synced + cleared {queue_path.name}.")
        else:
            print(f"[QUEUE]      {queue_path.name} still pending ({result.status}).")

    print(f"[QUEUE]      Drain complete. {drained}/{len(queued)} synced.")


# ---------------------------------------------------------------------------
# Automated file watcher (Milestone 1)
# ---------------------------------------------------------------------------

class TranscriptHandler(FileSystemEventHandler):
    """Watchdog handler that processes each new ``.txt`` transcript on arrival."""

    def __init__(self, config: Config) -> None:
        super().__init__()
        self.config = config

    def _handle_path(self, raw_path: str) -> None:
        path = Path(raw_path)
        if path.suffix.lower() != ".txt":
            return
        # Ignore files that may already have been moved/processed.
        if not path.exists():
            return
        print(f"\n[WATCH]      New transcript detected: {path.name}")
        if not wait_for_file_stable(path):
            print(f"[WATCH]      {path.name} never stabilized; skipping for now.")
            return
        process_single_file(self.config, path)

    def on_created(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._handle_path(event.src_path)

    def on_moved(self, event: FileSystemEvent) -> None:
        # Editors often write to a temp file then rename into place.
        if not event.is_directory:
            self._handle_path(event.dest_path)


def start_watch(config: Config) -> None:
    """Start watching ``./transcripts/`` and block until interrupted."""
    observer = Observer()
    handler = TranscriptHandler(config)
    observer.schedule(handler, path=str(TRANSCRIPTS_DIR), recursive=False)
    observer.start()
    print(f"\n[WATCH]      Watching {TRANSCRIPTS_DIR} for new .txt files. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[WATCH]      Stopping watcher...")
        observer.stop()
    observer.join()
    print("[WATCH]      Watcher stopped.")


# ---------------------------------------------------------------------------
# Batch processing + entry point
# ---------------------------------------------------------------------------

def process_existing_transcripts(config: Config) -> None:
    """Process every ``.txt`` currently sitting in ``./transcripts/``."""
    transcripts = sorted(TRANSCRIPTS_DIR.glob("*.txt"))
    if not transcripts:
        print(f"[INFO]       No .txt transcripts in {TRANSCRIPTS_DIR}.")
        return

    print(f"[INFO]       Found {len(transcripts)} transcript(s). Processing...")
    tally = {"SYNCED": 0, "QUEUED": 0, "FAILED": 0}
    for transcript_path in transcripts:
        status = process_single_file(config, transcript_path)
        tally[status] = tally.get(status, 0) + 1

    print(
        f"\n[SUMMARY]    {tally['SYNCED']} synced, "
        f"{tally['QUEUED']} queued, {tally['FAILED']} failed."
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Penlo local transcript ingestion pipeline.",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="After the initial batch, watch transcripts/ for new files continuously.",
    )
    parser.add_argument(
        "--retry-queue",
        action="store_true",
        help="Only attempt to drain the offline queue/, then exit.",
    )
    parser.add_argument(
        "--no-sync",
        action="store_true",
        help="Local-only mode: extract + validate + buffer to queue, never call the network.",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    """Entry point."""
    args = build_arg_parser().parse_args(argv)

    ensure_workspace_dirs()

    try:
        config = init_config(force_no_sync=args.no_sync)
    except RuntimeError as exc:
        print(f"[FATAL] {exc}", file=sys.stderr)
        return 1

    # Mode 1: queue-drain only.
    if args.retry_queue:
        retry_queue(config)
        return 0

    # Always: process anything already waiting, then try to drain the queue.
    process_existing_transcripts(config)
    retry_queue(config)

    # Mode 2: continuous watching.
    if args.watch:
        start_watch(config)

    return 0


if __name__ == "__main__":
    sys.exit(main())
