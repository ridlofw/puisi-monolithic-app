# Indonesian Piper synthesis

`suara.py` normalizes poem text, rejects empty and punctuation-only input, splits it at blank lines, synthesizes each stanza with Piper, inserts a configurable silence, combines PCM WAV audio, and encodes/verifies an MP3 with FFmpeg and ffprobe. The Piper adapter sends text on stdin using an argv list; it does not construct a shell command from poem text.

## Build and run

```sh
docker build -t puisi-tts-i2 workers/text-to-speech
docker run --rm puisi-tts-i2
```

For a local synthesis after building:

```sh
docker run --rm -v "$PWD:/work" puisi-tts-i2 python suara.py /work/puisi.txt /work/puisi.mp3
```

The image downloads the `id_ID-news_tts-medium` Piper model and its JSON configuration from the `rhasspy/piper-voices` Hugging Face repository at revision `9f967d15e9ccdf43078586d1476ee70f314401bd`. The model and config are checked against the repository catalog MD5 values (`17de01db7ac654655436b6e509893c72` and `c023cfa031cc9ed4cf5dd8d2ef1e48ed`). Model binaries are not stored in Git.

The repository folder is marked MIT, but its model card points to training data whose licensing terms are unclear. Treat this as a provenance limitation and confirm redistribution rights for the model before using it commercially. The model card also identifies it as fine-tuned from an English voice; pronunciation of Indonesian names, loanwords, and poetic diction may need review. The model card and upstream voice listing are linked here: [voice files](https://huggingface.co/rhasspy/piper-voices/tree/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium) and [model card](https://huggingface.co/rhasspy/piper-voices/blob/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium/MODEL_CARD).

`TTS_STANZA_PAUSE_MS` controls the inter-stanza pause (default `650`). `PIPER_MODEL` selects the model path (default `/opt/voices/id_ID-news_tts-medium.onnx`). The command-line tool accepts UTF-8 text-file and MP3 output paths. It prints the verified audio duration and processing time after successful synthesis.

Unit tests run in the image by default and can also be run with `python -m unittest discover -s workers/text-to-speech/tests -v` from the repository root.
