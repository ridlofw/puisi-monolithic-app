"""Indonesian poem text preparation and speech synthesis utilities."""
from __future__ import annotations

import math
import os
import re
import subprocess
import tempfile
import time
import unicodedata
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


MODEL = os.environ.get("PIPER_MODEL", "/opt/voices/id_ID-news_tts-medium.onnx")
PAUSE_BETWEEN_STANZAS_MS = int(os.environ.get("TTS_STANZA_PAUSE_MS", "650"))


class SynthesisError(RuntimeError):
    """Raised when the engine or audio conversion fails."""


@dataclass(frozen=True)
class SynthesisResult:
    path: Path
    duration_seconds: float
    processing_seconds: float


class SpeechEngine(Protocol):
    def synthesize(self, text: str, output_wav: Path) -> None:
        """Synthesize text into a PCM WAV file."""


class PiperEngine:
    """Piper adapter using argv and stdin; poem text is never shell-interpolated."""

    def __init__(self, model: str | Path = MODEL, timeout_seconds: int = 180):
        self.model = str(model)
        self.timeout_seconds = timeout_seconds

    def synthesize(self, text: str, output_wav: Path) -> None:
        command = [
            "python", "-m", "piper", "--model", self.model,
            "--output-file", str(output_wav), "--sentence-silence", "0.15",
        ]
        try:
            result = subprocess.run(
                command, input=text, text=True, capture_output=True,
                check=False, timeout=self.timeout_seconds,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise SynthesisError(f"Piper could not run: {exc}") from exc
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "no engine details").strip()[-1000:]
            raise SynthesisError(f"Piper failed with exit code {result.returncode}: {detail}")
        if not output_wav.is_file() or output_wav.stat().st_size == 0:
            raise SynthesisError("Piper returned success without a WAV file.")


SENTENCE_SILENCE_SECONDS = 0.15


def _load_piper_voice(model: str):
    from piper import PiperVoice
    return PiperVoice.load(model)


class ResidentPiperEngine:
    """Hot start: the voice model is loaded once per worker process and reused for every stanza.

    The CLI engine above starts a new Python process and reloads the ONNX model for every stanza.
    Output matches the CLI: each non-empty line is synthesized on its own and sentence chunks
    within a line are separated by the same silence as --sentence-silence.
    """

    def __init__(self, model: str | Path = MODEL, sentence_silence: float = SENTENCE_SILENCE_SECONDS,
                 loader=_load_piper_voice):
        self.model = str(model)
        self.sentence_silence = sentence_silence
        self._loader = loader
        self._voice = None
        self.load_seconds = 0.0

    def voice(self):
        if self._voice is None:
            started = time.monotonic()
            try:
                self._voice = self._loader(self.model)
            except Exception as exc:
                raise SynthesisError(f"Piper voice could not be loaded: {exc}") from exc
            self.load_seconds = time.monotonic() - started
        return self._voice

    def synthesize(self, text: str, output_wav: Path) -> None:
        voice = self.voice()
        silence = bytes(int(voice.config.sample_rate * self.sentence_silence) * 2)
        frames = []
        fmt = None
        try:
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                for index, chunk in enumerate(voice.synthesize(line)):
                    if fmt is None:
                        fmt = (chunk.sample_rate, chunk.sample_width, chunk.sample_channels)
                    if index > 0:
                        frames.append(silence)
                    frames.append(chunk.audio_int16_bytes)
        except Exception as exc:
            raise SynthesisError(f"Piper failed: {exc}") from exc
        if fmt is None:
            raise SynthesisError("Piper produced no audio.")
        with wave.open(str(output_wav), "wb") as wav:
            wav.setframerate(fmt[0])
            wav.setsampwidth(fmt[1])
            wav.setnchannels(fmt[2])
            wav.writeframes(b"".join(frames))


_default_engine = None


def default_engine():
    """One engine per process. TTS_ENGINE=cli keeps the old per-stanza subprocess for comparison."""
    global _default_engine
    if _default_engine is None:
        _default_engine = PiperEngine() if os.environ.get("TTS_ENGINE", "resident") == "cli" else ResidentPiperEngine()
    return _default_engine


def warm_up(engine=None) -> float:
    """Load the model and synthesize one word before the first job, so no user waits on a cold start."""
    engine = engine or default_engine()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="tts-warm-") as temp_dir:
        engine.synthesize("Halo.", Path(temp_dir) / "warm.wav")
    return time.monotonic() - started


def clean_text(text: str) -> str:
    """Normalize line endings and whitespace while retaining stanza boundaries."""
    if not isinstance(text, str):
        raise ValueError("Poem text must be a string.")
    normalized = unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    for line in normalized.split("\n"):
        cleaned = "".join(ch if ch in "\t\n" or unicodedata.category(ch)[0] != "C" else " " for ch in line)
        cleaned = re.sub(r"[\t \f\v]+", " ", cleaned).strip()
        lines.append(cleaned)
    return "\n".join(lines).strip()


def split_stanzas(text: str) -> list[str]:
    """Return non-empty stanzas; line breaks within a stanza remain meaningful."""
    cleaned = clean_text(text)
    if not cleaned or not any(char.isalnum() for char in cleaned):
        raise ValueError("Poem text must contain letters or numbers.")
    return [stanza.strip() for stanza in re.split(r"\n\s*\n+", cleaned) if stanza.strip()]


def combine_stanzas(wav_paths: list[Path], output_wav: Path, pause_ms: int) -> None:
    """Concatenate Piper PCM WAVs with silence between stanzas."""
    if not wav_paths:
        raise SynthesisError("No stanza audio was generated.")
    if pause_ms < 0:
        raise ValueError("Stanza pause cannot be negative.")

    output_wav.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(wav_paths[0]), "rb") as first:
        params = first.getparams()
        if params.comptype != "NONE" or params.sampwidth != 2:
            raise SynthesisError("Piper WAV must use uncompressed 16-bit PCM.")
        sample_rate = params.framerate
        channels = params.nchannels

    frames_per_pause = round(sample_rate * pause_ms / 1000)
    silence = b"\x00\x00" * channels * frames_per_pause
    with wave.open(str(output_wav), "wb") as combined:
        combined.setnchannels(channels)
        combined.setsampwidth(2)
        combined.setframerate(sample_rate)
        for index, wav_path in enumerate(wav_paths):
            with wave.open(str(wav_path), "rb") as stanza:
                current = stanza.getparams()
                if (current.nchannels, current.sampwidth, current.framerate, current.comptype) != (
                    channels, 2, sample_rate, "NONE"
                ):
                    raise SynthesisError("Piper produced incompatible WAV formats between stanzas.")
                if index:
                    combined.writeframes(silence)
                while frames := stanza.readframes(8192):
                    combined.writeframes(frames)


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(command, text=True, capture_output=True, check=False, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SynthesisError(f"Audio tool could not run: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "no tool details").strip()[-1000:]
        raise SynthesisError(f"Audio tool failed with exit code {result.returncode}: {detail}")
    return result


def synthesize_poem(
    text: str,
    output_mp3: str | Path,
    engine: SpeechEngine | None = None,
    pause_ms: int = PAUSE_BETWEEN_STANZAS_MS,
) -> SynthesisResult:
    """Synthesize stanzas, add pauses, encode MP3, and inspect its duration."""
    stanzas = split_stanzas(text)
    destination = Path(output_mp3)
    destination.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    speech_engine = engine or default_engine()

    with tempfile.TemporaryDirectory(prefix="tts-") as temp_dir:
        temp = Path(temp_dir)
        wav_paths = []
        for index, stanza in enumerate(stanzas):
            wav_path = temp / f"stanza-{index:03d}.wav"
            speech_engine.synthesize(stanza, wav_path)
            if not wav_path.is_file() or wav_path.stat().st_size == 0:
                raise SynthesisError(f"Speech engine produced no audio for stanza {index + 1}.")
            wav_paths.append(wav_path)

        combined_wav = temp / "combined.wav"
        combine_stanzas(wav_paths, combined_wav, pause_ms)
        _run([
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(combined_wav), "-codec:a", "libmp3lame", "-q:a", "3", str(destination),
        ])
        if not destination.is_file() or destination.stat().st_size == 0:
            raise SynthesisError("ffmpeg returned success without an MP3 file.")
        probe = _run([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", str(destination),
        ])
        try:
            duration = float(probe.stdout.strip())
        except ValueError as exc:
            raise SynthesisError("ffprobe returned an invalid audio duration.") from exc
        if not math.isfinite(duration) or duration <= 0:
            raise SynthesisError("Generated MP3 has no valid duration.")

    return SynthesisResult(destination, duration, time.monotonic() - started)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Synthesize Indonesian poem text to MP3.")
    parser.add_argument("input", help="UTF-8 text file containing a poem")
    parser.add_argument("output", help="Destination MP3 file")
    args = parser.parse_args()
    poem = Path(args.input).read_text(encoding="utf-8")
    result = synthesize_poem(poem, args.output)
    print(f"mp3={result.path} duration_seconds={result.duration_seconds:.3f} processing_seconds={result.processing_seconds:.3f}")
