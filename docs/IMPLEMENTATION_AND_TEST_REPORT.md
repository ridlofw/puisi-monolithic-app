# Implementation and test report — `ifham/text-to-speech`

Date: 2026-11-09 (Asia/Jakarta)

## Repository and branch

- Repository root: `D:/codes/testing/scalable-2/text-to-speech/puisi-monolithic-app-main`
- Current branch: `ifham/text-to-speech`
- Branch base: `2d0e1e88906caaa2dc64eb3d8b33273ee4827ef3`
- I2 commit: `2b8b00b` — `feat: synthesize Indonesian speech from poem text with Piper`
- I3 commit: `06ecabd` — `feat: run text-to-speech as a worker storing audio in S3 storage`
- Both feature commits are on `origin/ifham/text-to-speech`.
- `main` and `ifham/layanan-auth` were not modified in this session.

## ZIP reconciliation and architecture

The supplied ZIP contains 143 files. All 143 paths exist in the checked-out baseline and match their Git contents byte-for-byte. No ZIP files were extracted over the repository.

The shared event envelope and `audio.siap` payload match `kontrak/README.md`. The existing `q.text-to-speech` quorum queue, binding, and DLQ are already declared in `rabbitmq/definitions.json`; the worker consumes that queue without redeclaring it. Retry headers follow `workers/_templat/worker.py`. The event contains the poem text, so the worker has no runtime dependency on poem-service. `gateway/rute/audio.conf` serves the S3 object through SeaweedFS’s S3 API rather than treating the bucket as a local filesystem.

## I2 — Piper synthesis

Implemented in `workers/text-to-speech/`:

- Normalization, empty/punctuation-only rejection, stanza splitting, silence insertion, a thin Piper engine adapter, PCM combination, MP3 encoding, ffprobe duration, and elapsed processing time.
- Piper receives poem content on stdin as an argument-vector subprocess, without shell interpolation.
- The Docker image installs Piper and FFmpeg and fetches the Indonesian `id_ID-news_tts-medium` voice at pinned revision `9f967d15e9ccdf43078586d1476ee70f314401bd`. Both model files are checked against their catalog MD5s. Model binaries are not in Git.
- The voice folder is marked MIT, but the model card points to training data with unclear licensing terms. Confirm model redistribution rights before commercial use. The model card also notes English-voice fine-tuning; pronunciation of Indonesian names and poetic diction may need review. Sources: [pinned voice files](https://huggingface.co/rhasspy/piper-voices/tree/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium), [pinned model card](https://huggingface.co/rhasspy/piper-voices/blob/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium/MODEL_CARD).

## I3 — queue worker, job store, S3, gateway

- `compose/text-to-speech.yaml` configures MySQL 8.4, SeaweedFS 4.53, bucket initialization, and two worker replicas. The job database and object store have named volumes and health/readiness dependencies.
- `job` has unique `puisi_id`, constrained states, a persisted attempt count, and a 15-minute lease token. Duplicate events are serialized by MySQL row locks. Audio writes use the deterministic key `puisi_<id>.mp3`.
- Job completion and its `audio.siap` event are committed together in `event_outbox`. A separate relay uses RabbitMQ publisher confirms before marking each event published. An event repeated after a confirm/crash has the same stored event ID.
- The consumer uses prefetch 1, reuses the project envelope, retries transient processing errors up to three times, and routes exhausted or malformed messages to the existing DLQ. Permanent invalid events go directly to the DLQ. Broker reconnection and SIGTERM/SIGINT handling are implemented.
- SeaweedFS is not published on a host port. Generated local secrets give the worker read/write/list only in bucket `audio`, the initializer an audio-bucket admin policy, and the gateway anonymous read-only access only to that bucket. The gateway accepts GET/HEAD on `/audio/`, denies other methods, returns MP3 content type, and applies a one-day cache policy.
- `scripts/siapkan_rahasia_tts.py` generates ignored local credentials. Do not commit files in `secrets/`.

## Tests actually run

| Check | Result | Evidence |
|---|---|---|
| Compose fragment validation | PASS | `docker compose --profile tts config --quiet` |
| I2/I3 unit suite in the built image | PASS | `docker compose --profile tts run --rm --no-deps --entrypoint python text-to-speech -m unittest discover -s tests -v`; 16 tests passed |
| Four-line Indonesian synthesis in Docker | PASS | MP3 size 63,179 bytes; ffprobe duration 8.098 s; Piper processing 1.621 s |
| Event-to-audio smoke test | PASS | `scripts/kirim_event.py` published `puisi.dibuat`; job 1 reached `selesai`; `puisi_1.mp3` stored in bucket `audio` (61,330 bytes, 7.863 s) |
| Completion event | PASS | `q.tap` showed `audio.siap` with `puisi_id=1`, `url_audio=/audio/puisi_1.mp3`, `durasi_detik=7.863`, and `mesin=piper-id_ID-news_tts-medium` |
| Gateway playback response | PASS | GET and HEAD returned 200; 61,330 bytes; `Content-Type: audio/mpeg`; one-day cache expiry. PUT returned 403 |
| Two worker replicas | PASS | Both configured replicas reported healthy and consumed `q.text-to-speech` |
| Duplicate delivery | PASS | Same event was sent three times total; one job row (`selesai`), one canonical object, one outbox row/completion event |
| Malformed event to DLQ | PASS | Raw malformed sample was rejected; DLQ count increased |
| Storage outage / retry exhaustion | PASS | With SeaweedFS stopped, job 41000 reached `gagal`, `attempt_count=3`, and `q.text-to-speech.dlq` increased; SeaweedFS was restarted and became healthy |
| Upload succeeds, DB completion fails | PASS (unit simulation) | Worker test confirms retry keeps the deterministic object key and does not acknowledge before retry publish |
| Outbox publish confirmation | PASS (unit simulation) | Confirmed publish marks the row; unconfirmed publish leaves it pending |
| Secret handling / Git | PASS | TTS secrets are generated under ignored `secrets/`; no secret file or model binary is tracked |

## Load measurements

Each run published 20 unique four-line Indonesian poem events and waited for all jobs to reach a terminal state. Environment: Windows Docker Desktop (`desktop-linux`), Python 3.12 worker image, Piper `id_ID-news_tts-medium`, SeaweedFS 4.53, MySQL 8.4, RabbitMQ 4.4.0. Only RabbitMQ node 1 was active during this targeted run, and the quorum queue had one active member; these are local comparative measurements, not a production cluster benchmark.

| Worker replicas | Jobs completed | Drain time | Throughput |
|---:|---:|---:|---:|
| 2 | 20/20 | 21.266 s | 0.940 jobs/s |
| 4 | 20/20 | 16.357 s | 1.223 jobs/s |
| 4 (repeat) | 20/20 | 15.293 s | 1.308 jobs/s |

The four-replica runs were faster in these small runs. A sampled `docker stats` snapshot during the repeat showed worker containers at 0.04–0.15% CPU, `tts-db` at 4.21%, SeaweedFS at 0.49%, and RabbitMQ at 0.84%; this is a single instantaneous sample, not peak utilization. The two-replica deployment setting was restored after benchmarking.

## Retry and recovery notes

Verified: permanent malformed input to DLQ, three-attempt object-storage failure to DLQ with a persisted failed job, duplicate processing, idempotent object naming, database failure after upload through a unit simulation, and outbox publish confirmation behavior through unit simulations.

Not exercised against live services: RabbitMQ outage, MySQL outage, process termination during Piper synthesis, and broker confirmation loss after `audio.siap` publish. The code uses persistent input messages, unacked-delivery redelivery, DB leases, deterministic object keys, and a transactional outbox for these cases. RabbitMQ quorum replication across all three nodes was not verified in this run; only RabbitMQ node 1 was running.

## Remaining limitations and delivery state

- Verify licensing/provenance of the Indonesian voice before any redistribution or commercial deployment.
- Run the full three-node RabbitMQ profile to verify quorum membership and broker failover.
- Live DB-outage and worker-kill recovery tests remain NOT RUN.
- The three-node RabbitMQ quorum and live database-outage/worker-kill recovery checks remain unverified as described above.
