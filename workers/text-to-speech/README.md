# Indonesian Piper synthesis

`suara.py` normalizes poem text, rejects empty and punctuation-only input, splits it at blank lines, synthesizes each stanza with Piper, inserts a configurable silence, combines PCM WAV audio, and encodes/verifies an MP3 with FFmpeg and ffprobe. The Piper adapter sends text on stdin using an argv list; it does not construct a shell command from poem text.

## Build and run

```sh
docker build -f workers/text-to-speech/Dockerfile -t puisi-tts-i2 .
docker run --rm puisi-tts-i2
```

## Asynchronous deployment (I3)

From the repository root, generate local credentials and start the TTS profile:

```sh
python scripts/siapkan_rahasia_tts.py
docker compose --profile tts up -d --build tts-db seaweedfs tts-audio-init text-to-speech
docker compose --profile tts ps
```

`siapkan_rahasia_tts.py` creates local, Git-ignored password files and an S3 policy file without printing credential values. SeaweedFS exposes no host ports. Its worker identity can read/write/list only in `audio`; a separate initializer identity can administer that bucket to create it; anonymous access is read-only and scoped to `audio` so the gateway can serve `/audio/<key>`. The S3 endpoint is `S3_ENDPOINT` and can be pointed to an Amazon S3 endpoint with corresponding credentials/policy.

RabbitMQ queues are owned by `rabbitmq/definitions.json`; this worker consumes `q.text-to-speech` with prefetch 1 and does not declare queues. The message envelope is defined in `kontrak/README.md`. Publish the supplied contract sample with `python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json`. Inspect completion events with `python scripts/intip_event.py --tipe audio.siap --tunggu 15`, and job state from MySQL with:

```sh
docker exec puisi-text-to-speech-1 python -c "import pymysql; c=pymysql.connect(host='tts-db',user='tts',password=open('/run/secrets/tts_db_password').read().strip(),database='tts'); q=c.cursor(); q.execute('SELECT puisi_id,status,audio_key,durasi_detik,attempt_count,last_error FROM job'); print(q.fetchall())"
```

`job` uses a unique `puisi_id`, row locks, attempt count, and an expiring lease token to serialize replicas and recover a delivery after a worker crash. Audio objects use the deterministic key `puisi_<id>.mp3`. A committed completion and its `audio.siap` body are written together to `event_outbox`; an independent relay uses publisher confirms before marking the event sent. If it crashes after broker confirmation and before marking, it republishes the same event ID, which is safe for idempotent consumers. Uploads can safely repeat because the object key is deterministic. The shared RabbitMQ contract retry header is used for up to three delivery attempts, and exhausted/permanent failures are rejected to the configured DLQ.

The route `gateway/rute/audio.conf` proxies only `/audio/` to SeaweedFS and returns MP3 with a one-day cache policy. The completion event contains `puisi_id`, `/audio/puisi_<id>.mp3`, `durasi_detik`, and `mesin`. Use `docker compose --profile tts logs -f text-to-speech seaweedfs` for worker and storage logs. The worker service is configured for two replicas. For a temporary four-replica benchmark, use Compose `--scale text-to-speech=4`, then restore it to `2` afterward; the file remains configured for two.

MySQL init scripts run only when the `tts-db` volume is first created. Do not delete the volume to reset a database containing wanted data. Storage credentials are generated locally; keep all files in `secrets/` out of version control. The worker health endpoint is internal on port 9100 and exposes metrics only.

For a local synthesis after building:

```sh
docker run --rm -v "$PWD:/work" puisi-tts-i2 python suara.py /work/puisi.txt /work/puisi.mp3
```

The image downloads the `id_ID-news_tts-medium` Piper model and its JSON configuration from the `rhasspy/piper-voices` Hugging Face repository at revision `9f967d15e9ccdf43078586d1476ee70f314401bd`. The model and config are checked against the repository catalog MD5 values (`17de01db7ac654655436b6e509893c72` and `c023cfa031cc9ed4cf5dd8d2ef1e48ed`). Model binaries are not stored in Git.

The repository folder is marked MIT, but its model card points to training data whose licensing terms are unclear. Treat this as a provenance limitation and confirm redistribution rights for the model before using it commercially. The model card also identifies it as fine-tuned from an English voice; pronunciation of Indonesian names, loanwords, and poetic diction may need review. The model card and upstream voice listing are linked here: [voice files](https://huggingface.co/rhasspy/piper-voices/tree/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium) and [model card](https://huggingface.co/rhasspy/piper-voices/blob/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium/MODEL_CARD).

`TTS_STANZA_PAUSE_MS` controls the inter-stanza pause (default `650`). `PIPER_MODEL` selects the model path (default `/opt/voices/id_ID-news_tts-medium.onnx`). The command-line tool accepts UTF-8 text-file and MP3 output paths. It prints the verified audio duration and processing time after successful synthesis.

Unit tests run in the image by default and can also be run with `python -m unittest discover -s workers/text-to-speech/tests -v` from the repository root.
