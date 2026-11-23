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


class FakeChunk:
    def __init__(self, payload):
        self.sample_rate = 100
        self.sample_width = 2
        self.sample_channels = 1
        self.audio_int16_bytes = payload


class FakeVoice:
    def __init__(self):
        self.config = type("Config", (), {"sample_rate": 100})()
        self.lines = []

    def synthesize(self, line):
        self.lines.append(line)
        # two sentence chunks per line, like Piper does for "A. B."
        return [FakeChunk(b"\x01\x00" * 5), FakeChunk(b"\x02\x00" * 5)]


class TestResidentEngine(unittest.TestCase):
    def test_model_is_loaded_once_for_many_stanzas(self):
        loads = []
        voice = FakeVoice()

        def loader(model):
            loads.append(model)
            return voice

        engine = suara.ResidentPiperEngine(model="/model.onnx", loader=loader)
        with tempfile.TemporaryDirectory() as directory:
            for index in range(3):
                engine.synthesize("baris satu\nbaris dua", Path(directory) / f"s{index}.wav")
        self.assertEqual(loads, ["/model.onnx"])
        self.assertEqual(voice.lines, ["baris satu", "baris dua"] * 3)

    def test_output_matches_cli_silence_rule(self):
        engine = suara.ResidentPiperEngine(loader=lambda _: FakeVoice(), sentence_silence=0.1)
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out.wav"
            engine.synthesize("satu\n\n  \ndua", out)
            with wave.open(str(out), "rb") as wav:
                self.assertEqual(wav.getframerate(), 100)
                # per line: 5 frames, 10 frames of silence between the two chunks, 5 frames
                self.assertEqual(wav.getnframes(), 2 * (5 + 10 + 5))

    def test_engine_errors_become_synthesis_errors(self):
        def broken(_):
            raise RuntimeError("model missing")

        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(suara.SynthesisError):
                suara.ResidentPiperEngine(loader=broken).synthesize("teks", Path(directory) / "x.wav")

    def test_no_audio_is_rejected(self):
        class Silent(FakeVoice):
            def synthesize(self, line):
                return []

        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(suara.SynthesisError):
                suara.ResidentPiperEngine(loader=lambda _: Silent()).synthesize("teks", Path(directory) / "x.wav")

    def test_cli_engine_can_still_be_selected(self):
        with patch.dict("os.environ", {"TTS_ENGINE": "cli"}), patch.object(suara, "_default_engine", None):
            self.assertIsInstance(suara.default_engine(), suara.PiperEngine)


if __name__ == "__main__":
    unittest.main()
