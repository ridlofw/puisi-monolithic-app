import tempfile
import unittest
import wave
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import suara


class FakeEngine:
    def __init__(self, frames=2205):
        self.frames = frames
        self.texts = []

    def synthesize(self, text, output_wav):
        self.texts.append(text)
        with wave.open(str(output_wav), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(22050)
            wav.writeframes(b"\x01\x00" * self.frames)


class TestTeks(unittest.TestCase):
    def test_clean_text_normalizes_unicode_and_line_endings(self):
        self.assertEqual(suara.clean_text("  Hujan\r\n  turun   lagi. \r\n"), "Hujan\nturun lagi.")

    def test_split_stanzas_preserves_lines_and_removes_empty_stanzas(self):
        self.assertEqual(suara.split_stanzas("Bait satu\nBaris dua\n\n\nBait berikut"), [
            "Bait satu\nBaris dua", "Bait berikut",
        ])

    def test_empty_and_punctuation_only_input_are_rejected(self):
        for value in ("", "  \n ", "... — !!!"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                suara.split_stanzas(value)

    def test_non_string_input_is_rejected(self):
        with self.assertRaises(ValueError):
            suara.clean_text(None)


class TestAudioHandling(unittest.TestCase):
    def test_pause_is_inserted_between_wavs(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            engine = FakeEngine(frames=2205)
            wavs = []
            for index in range(2):
                path = base / f"{index}.wav"
                engine.synthesize(f"bait {index}", path)
                wavs.append(path)
            combined = base / "combined.wav"
            suara.combine_stanzas(wavs, combined, pause_ms=500)
            with wave.open(str(combined), "rb") as wav:
                self.assertEqual(wav.getframerate(), 22050)
                self.assertEqual(wav.getnframes(), 2 * 2205 + 11025)

    def test_negative_pause_is_rejected(self):
        with self.assertRaises(ValueError):
            suara.combine_stanzas([Path("unused.wav")], Path("out.wav"), pause_ms=-1)

    def test_piper_receives_text_on_stdin_without_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "voice.wav"
            completed = type("Process", (), {"returncode": 0, "stderr": "", "stdout": ""})()
            with patch("suara.subprocess.run", return_value=completed) as run:
                engine = suara.PiperEngine(model="/model.onnx")

                def create_output(*args, **kwargs):
                    with wave.open(str(output), "wb") as wav:
                        wav.setnchannels(1)
                        wav.setsampwidth(2)
                        wav.setframerate(22050)
                        wav.writeframes(b"\x00\x00" * 100)
                    return completed

                run.side_effect = create_output
                engine.synthesize("untrusted; text", output)
                argv = run.call_args.args[0]
                self.assertEqual(argv[0:3], ["python", "-m", "piper"])
                self.assertNotIn("untrusted; text", argv)
                self.assertEqual(run.call_args.kwargs["input"], "untrusted; text")
                self.assertFalse(run.call_args.kwargs.get("shell", False))

    def test_mp3_pipeline_records_duration_and_processing_time(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "poem.mp3"
            engine = FakeEngine()

            def fake_tool(argv, **kwargs):
                if argv[0] == "ffmpeg":
                    Path(argv[-1]).write_bytes(b"fake mp3")
                    return type("Process", (), {"returncode": 0, "stderr": "", "stdout": ""})()
                return type("Process", (), {"returncode": 0, "stderr": "", "stdout": "2.5\n"})()

            with patch("suara.subprocess.run", side_effect=fake_tool):
                result = suara.synthesize_poem("Satu bait\n\nBait kedua", output, engine=engine, pause_ms=200)
            self.assertTrue(output.is_file())
            self.assertEqual(engine.texts, ["Satu bait", "Bait kedua"])
            self.assertEqual(result.duration_seconds, 2.5)
            self.assertGreaterEqual(result.processing_seconds, 0)


if __name__ == "__main__":
    unittest.main()
