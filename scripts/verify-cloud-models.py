#!/usr/bin/env python3
"""Probe every recommended cloud model with the app's own request shape.

WARNING: THIS MAKES REAL, BILLABLE API CALLS to OpenRouter, one per recommended
model. Run it deliberately, by hand, when the model list or the request body
changes. It must NEVER run in CI: CI has no key, and a workflow that quietly
spends money on every push is a bad trade for a check nobody reads.

WHY THIS EXISTS. The recommended list used to carry a comment claiming every
entry was "empirically verified via a real transcription test". That claim went
stale and then became false: half the list was broken, and most of the breakage
was caused by the app's own payload rather than by the models. A comment cannot
be re-run. This can.

WHAT IT CHECKS. That each recommended model actually RECEIVES the audio part and
can describe it. The prompt asks the model to describe what it hears and gives it
an explicit NO_AUDIO_RECEIVED escape hatch. That distinction matters: a model that
never gets the audio will happily invent a plausible transcript when asked to
transcribe, which reads as success. Asking it to describe, with a way to say "I
got nothing", is what makes the failure unambiguous.

WHAT IT DOES NOT CHECK. It does not pin `provider.only` the way the app does,
because it is verifying MODEL capability, not the provider picker. A model can
pass here and still fail for one specific provider.

Usage:
    OPENROUTER_API_KEY=... python3 scripts/verify-cloud-models.py
    python3 scripts/verify-cloud-models.py --key-file ~/path/to/keyfile

Exits 0 when every recommended model passes, 1 when any fails, so it can gate a
release. Standard library only: no pip install, on any machine.
"""

import argparse
import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import wave
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "NockerlVoice/Transcription/CloudProviderCatalog.swift"
ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

# The escape hatch is the whole point. See the module docstring.
INSTRUCTION = (
    "Describe what you hear in this audio in a few words. "
    "If you did not receive any audio, reply with exactly NO_AUDIO_RECEIVED and nothing else."
)

TONE_HZ = 440
TONE_SECONDS = 2
SAMPLE_RATE = 16_000


# ---------------------------------------------------------------- key handling

def load_key(key_file: str | None) -> str:
    """Read the API key from a file or the environment.

    The key is never printed, never logged, and never written anywhere. It is
    returned to the caller and used only as an Authorization header value.
    """
    if key_file:
        try:
            key = Path(key_file).expanduser().read_text(encoding="utf-8").strip()
        except OSError as exc:
            sys.exit(f"error: could not read the key file: {exc.strerror}")
    else:
        key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        sys.exit(
            "error: no API key. Set OPENROUTER_API_KEY, or pass --key-file PATH.\n"
            "       The key is only ever sent to OpenRouter, and is never printed."
        )
    return key


def redact(text: str, key: str) -> str:
    """Belt and braces: strip the key from anything on its way to stdout.

    Nothing here should ever contain it (the key goes into a header, and error
    bodies come back from OpenRouter), but output is the one place a leak would
    become permanent, in a terminal log or a pasted report.
    """
    return text.replace(key, "[REDACTED]") if key else text


# ------------------------------------------------------- catalog (the app data)

def _swift_string_list(source: str, symbol: str) -> list[str]:
    """Pull the string literals out of a Swift array or set literal.

    Deliberately parsed from the app rather than duplicated here. A hardcoded copy
    is exactly how the original claim drifted out of date: the script has to test
    what the app actually ships, including its routing rules.
    """
    match = re.search(rf"{symbol}[^=]*=\s*\[(.*?)\]", source, re.S)
    if not match:
        sys.exit(f"error: could not find {symbol} in {CATALOG.name}. Has the catalog moved?")
    return re.findall(r'"([^"]+)"', match.group(1))


def load_catalog() -> tuple[list[str], list[str], list[str]]:
    try:
        source = CATALOG.read_text(encoding="utf-8")
    except OSError as exc:
        sys.exit(f"error: could not read the catalog: {exc.strerror}")
    models = _swift_string_list(source, "recommendedModelIDs")
    reasoning_mandatory = _swift_string_list(source, "reasoningMandatoryPrefixes")
    zdr_incompatible = _swift_string_list(source, "zdrIncompatiblePrefixes")
    if not models:
        sys.exit("error: the recommended model list is empty.")
    return sorted(models), reasoning_mandatory, zdr_incompatible


def has_prefix(model: str, prefixes: list[str]) -> bool:
    lowered = model.lower()
    return any(lowered.startswith(p.lower()) for p in prefixes)


# ------------------------------------------------------------------- test audio

def make_tone(directory: Path) -> tuple[Path, str]:
    """Write a short tone and return its path and OpenRouter format name.

    Generated rather than committed: a binary fixture in the repo is one more
    thing to keep honest, and a tone is three lines of stdlib.
    """
    wav_path = directory / "tone.wav"
    frames = bytearray()
    for i in range(SAMPLE_RATE * TONE_SECONDS):
        # A plain square wave. The models only need to hear SOMETHING; a square
        # wave survives mp3 encoding far more legibly than a quiet sine.
        value = 12000 if (i // (SAMPLE_RATE // TONE_HZ // 2)) % 2 == 0 else -12000
        frames += struct.pack("<h", value)
    with wave.open(str(wav_path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))

    if not shutil.which("ffmpeg"):
        print("note: ffmpeg not found, probing with WAV instead of MP3.")
        print("      The app records MP3, so this exercises a slightly different path.")
        return wav_path, "wav"

    mp3_path = directory / "tone.mp3"
    result = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path), str(mp3_path)],
        capture_output=True,
    )
    if result.returncode != 0 or not mp3_path.exists():
        print("note: ffmpeg failed to encode, falling back to WAV.")
        return wav_path, "wav"
    return mp3_path, "mp3"


# ----------------------------------------------------------------------- probe

def build_payload(model: str, audio_b64: str, fmt: str,
                  reasoning_mandatory: list[str], zdr_incompatible: list[str]) -> dict:
    """Mirror OpenRouterProvider.requestBody, including its two exceptions.

    Both exceptions are read from the catalog, so this stays a real test of what
    the app sends. Getting either one wrong here would reproduce the exact bug
    this script exists to catch: sending `reasoning` to a model that mandates it
    reports a working model as broken.
    """
    payload = {
        "model": model,
        "temperature": 0,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": INSTRUCTION},
                {"type": "input_audio", "input_audio": {"data": audio_b64, "format": fmt}},
            ],
        }],
    }
    if not has_prefix(model, reasoning_mandatory):
        payload["reasoning"] = {"enabled": False}
    # The app always sends zdr, but a model with no ZDR endpoint can only be used
    # with the requirement off. Probing it with zdr on would test a configuration
    # the app already refuses, and would fail every run for a model that works.
    if not has_prefix(model, zdr_incompatible):
        payload["provider"] = {"zdr": True}
    return payload


def probe(model: str, payload: dict, key: str, timeout: int) -> tuple[str, str]:
    """Return (verdict, detail). Verdict is OK, NO_AUDIO, EMPTY, or FAIL."""
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://nockerl.ai",
            "X-Title": "Nockerl Voice",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = collapse(exc.read().decode("utf-8", "replace"))
        return "FAIL", f"HTTP {exc.code}: {detail}"
    except Exception as exc:  # noqa: BLE001 - any transport problem is a failure
        return "FAIL", f"transport: {exc}"

    if body.get("error"):
        return "FAIL", "api error: " + collapse(json.dumps(body["error"]))

    message = (body.get("choices") or [{}])[0].get("message") or {}
    content = message.get("content") or ""
    if isinstance(content, list):
        content = " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    # Same fallback the app's parser uses: some models put the text in `reasoning`
    # with content null.
    text = (content or message.get("reasoning") or "").strip()

    if not text:
        return "EMPTY", "no text in the response"
    if "NO_AUDIO_RECEIVED" in text.upper():
        return "NO_AUDIO", collapse(text)
    return "OK", collapse(text)


def collapse(text: str, limit: int = 90) -> str:
    flat = re.sub(r"\s+", " ", text).strip()
    return flat[:limit] + ("..." if len(flat) > limit else "")


# ------------------------------------------------------------------------ main

def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the recommended cloud models.")
    parser.add_argument("--key-file", help="path to a file containing the OpenRouter API key")
    parser.add_argument("--timeout", type=int, default=180, help="per-request timeout in seconds")
    args = parser.parse_args()

    key = load_key(args.key_file)
    models, reasoning_mandatory, zdr_incompatible = load_catalog()

    print(f"Probing {len(models)} recommended models. This spends real credit.")
    print(f"Reasoning omitted for: {', '.join(reasoning_mandatory) or 'nothing'}")
    print(f"Probed without the ZDR requirement: {', '.join(zdr_incompatible) or 'nothing'}")
    print()

    with tempfile.TemporaryDirectory() as tmp:
        audio_path, fmt = make_tone(Path(tmp))
        audio_b64 = base64.b64encode(audio_path.read_bytes()).decode()

        results = []
        for model in models:
            payload = build_payload(model, audio_b64, fmt, reasoning_mandatory, zdr_incompatible)
            verdict, detail = probe(model, payload, key, args.timeout)
            results.append((model, verdict, detail))
            print(f"  {verdict:<8} {model}")

    width = max(len(m) for m, _, _ in results)
    print()
    print(f"{'MODEL'.ljust(width)}  {'VERDICT':<8}  RESPONSE")
    print(f"{'-' * width}  {'-' * 8}  {'-' * 40}")
    for model, verdict, detail in results:
        print(f"{model.ljust(width)}  {verdict:<8}  {redact(detail, key)}")

    failed = [m for m, v, _ in results if v != "OK"]
    print()
    if failed:
        print(f"FAILED ({len(failed)} of {len(results)}): {', '.join(failed)}")
        print("Fix the model, or move it out of recommendedModelIDs in the catalog.")
        return 1
    print(f"All {len(results)} recommended models received the audio and described it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
