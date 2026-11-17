# Full implementation and test report — I1, I2, and I3

Date: 2026-11-09 (Asia/Jakarta)

## Executive summary

The assignment was completed as two independent feature-branch submissions. I1 is implemented and pushed on `ifham/layanan-auth`. I2 and I3 are implemented and pushed on `ifham/text-to-speech`. Both feature branches began at the same initial commit; neither was merged into `main`, and `main` was not modified. No pull request was created.

The auth service issues stateless HS256 JWTs compatible with the poem-service verifier. The TTS branch synthesizes Indonesian poems with Piper, consumes `puisi.dibuat`, persists jobs and completion events, stores MP3 objects in SeaweedFS, and serves them through the gateway. Live auth, TTS, duplicate-delivery, gateway, and storage-retry checks were performed. The three-node RabbitMQ cluster failover, live database outage, worker-kill recovery, and real-browser auth flow remain unverified.

## Repository and branch history

- Repository: `https://github.com/ridlofw/puisi-monolithic-app`
- Baseline commit: `2d0e1e88906caaa2dc64eb3d8b33273ee4827ef3`
- I1 branch: [`ifham/layanan-auth`](https://github.com/ridlofw/puisi-monolithic-app/tree/ifham/layanan-auth)
  - Commit `ff58195b18f2c53f8048922c0ea3ba5a730b3fa2` — `feat: replace PHP sessions with a stateless auth service issuing JWT`
- I2/I3 branch: [`ifham/text-to-speech`](https://github.com/ridlofw/puisi-monolithic-app/tree/ifham/text-to-speech)
  - Commit `2b8b00b9121178a718b1f1515c7c78ee81bf70c6` — `feat: synthesize Indonesian speech from poem text with Piper`
  - Commit `06ecabd19d65e2d7a8ab26d01f29bb8b3c026a75` — `feat: run text-to-speech as a worker storing audio in S3 storage`
  - Commit `004f62ae9aab692372f73f7685c41d9d1b8ee57a` — `docs: move implementation report under docs`
- The two feature branches retain separate histories. No merge or force-push was performed. The full report is an additional document on the TTS branch; the I1 branch retains its own branch-specific report.

## Initial reconnaissance and reconciliation

The repository root, current branch, commit, remote, and working-tree state were checked before implementation. Work was limited to the feature branch requested in each session. The existing contracts and service patterns were inspected before changes, including the poem-service JWT verifier, event envelope, RabbitMQ definitions, worker template, Compose fragments, gateway routes, and frontend request helper.

The archive `text-to-speech.zip` contains 143 files. All 143 paths were compared to the repository baseline and matched the Git object contents. The 41 reported raw differences against the Windows working copy were line-ending differences. `kontrak/README.md`, `web/js/api.js`, `web/js/auth.js`, `web/js/galeri.js`, `web/js/kirim.js`, `web/js/pencarian.js`, `web/index.html`, and `web/style.css` were inspected individually. No semantic differences were found in those files. The ZIP was never extracted over the repository, and no files were overwritten from it.

## I1 — Stateless auth service

### Implementation

The work is on `ifham/layanan-auth` only.

- Added `services/auth/` with registration, login, MySQL access, password hashing and verification, request validation, and JSON error handling. Duplicate usernames return HTTP 409; empty required fields return HTTP 400.
- Added an HS256 JWT issuer that reads `/run/secrets/jwt_secret`, follows the shared claim order (`sub`, `username`, `nama`, `iat`, `exp`), uses a one-hour lifetime, and emits the exact shared vector token.
- Preserved compatibility with `services/puisi/src/Jwt.php`, which verifies the raw base64url token segments.
- Configured MySQL 8.4 and two auth-service replicas sharing the same database and signing secret, with health checks and readiness dependencies.
- Added `gateway/rute/auth.conf` for `/api/auth/`, disabled caching, and rate-limited login.
- Updated `web/js/auth.js` to save, read, expire, and remove the token. Reused the existing `puisi.token` handling from `web/js/api.js`; auth requests omit browser cookies while poem requests retain their existing fetch credentials and bearer-token behavior.
- Kept `legacy/server.php` unchanged, including its non-auth poem actions and historical session paths. The active frontend authentication flow now uses `/api/auth/`.
- Documented that `localStorage` is exposed to JavaScript and therefore increases the impact of XSS. Browser-decoded claims control UI state only; backend authorization remains based on verified tokens.

### I1 checks

| Check | Status | Result |
|---|---|---|
| Shared JWT vector exact match | PASS | PHPUnit issued the exact `token_benar`; poem-service verifier accepted it and rejected expired and bad-signature vectors. |
| JWT claim order and one-hour expiry | PASS | PHPUnit asserted ordered claims and `exp = iat + 3600`. |
| Stateless auth source behavior | PASS | PHPUnit source check found no `session_start`, `$_SESSION`, or `setcookie` in the auth endpoint. |
| Frontend token lifecycle | PASS | Node simulation covered login, reload, logout, malformed/expired tokens, and token storage. |
| Auth and poem request credentials | PASS | Node simulation verified auth uses `credentials: omit`; poem calls retain `credentials: include` and the bearer header. |
| PHP/JS syntax, Python compile, Composer validation | PASS | Checks passed; Composer reported only its optional missing-license warning. |
| Compose configuration, secrets, DB, replica declaration | PASS | Compose resolved the MySQL 8.4 database, shared JWT secret, database secret, and `deploy.replicas: 2`. |
| Live validation, registration, duplicate, and wrong-password responses | PASS | User-run Docker integration observed 400, 201, 409, and 401 respectively. |
| Live login, no `Set-Cookie`, login rate limit | PASS | User-run integration sent 10 logins: `[200, 200, 200, 200, 200, 429, 429, 429, 429, 429]`; no login response included `Set-Cookie`. |
| Live two-replica token/user verification | PASS | User-run integration printed `verified` for both replicas. |
| Real browser login/reload/logout | NOT RUN | The Node frontend simulation passed; no real-browser result was reported. |

Earlier, the first live Docker attempt was blocked because the gateway was not running and the local HTTP test received connection refused. After the auth profile was started, the user supplied the successful integration output above. This later result supersedes the initial BLOCKED status in the original I1 report.

Useful I1 commands:

```sh
services/auth/vendor/bin/phpunit -c services/auth/phpunit.xml
node services/auth/tests/frontend.test.js
docker compose --profile auth up -d --build gateway auth-service
python services/auth/tests/integration.py
```

Local secret provisioning is documented in `services/auth/README.md`; secret values are not committed.

## I2 — Indonesian Piper synthesis

Implemented on `ifham/text-to-speech` in `workers/text-to-speech/`.

- `suara.py` normalizes text, rejects empty and punctuation-only input, splits stanzas, inserts pauses, synthesizes each stanza, combines WAV segments, encodes MP3 with FFmpeg, and reads duration with ffprobe.
- The Piper adapter passes poem text through stdin using an argv list; it does not interpolate poem text into a shell command.
- The Docker image installs Piper, FFmpeg, and the pinned Indonesian `id_ID-news_tts-medium` model. The model files use a pinned Hugging Face revision and catalog checksums; voice binaries are not committed.
- Voice provenance and pronunciation limitations are documented. The model folder is marked MIT, while its model card points to training data with unclear terms; confirm redistribution rights before commercial use. The model card also indicates fine-tuning from an English voice, so Indonesian names and poetic diction may need pronunciation review. See the [pinned voice files](https://huggingface.co/rhasspy/piper-voices/tree/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium) and [model card](https://huggingface.co/rhasspy/piper-voices/blob/9f967d15e9ccdf43078586d1476ee70f314401bd/id/id_ID/news_tts/medium/MODEL_CARD).

### I2 checks

| Check | Status | Result |
|---|---|---|
| Text cleanup and stanza unit tests | PASS | Included in the 16-test Docker suite. |
| Empty/punctuation-only input | PASS | Rejected by unit tests. |
| Pause handling and safe Piper subprocess | PASS | WAV silence frame count verified; test confirms poem content is provided on stdin without shell use. |
| Four-line Indonesian poem in Docker | PASS | MP3 size 63,179 bytes; ffprobe duration 8.098 seconds; Piper processing 1.621 seconds. |

## I3 — Asynchronous worker and S3-compatible audio

Implemented on the same `ifham/text-to-speech` branch.

- `compose/text-to-speech.yaml` configures MySQL 8.4, SeaweedFS 4.53, idempotent bucket initialization, and two TTS worker replicas. Secret files are generated locally by `scripts/siapkan_rahasia_tts.py` and ignored by Git.
- The worker consumes the existing `q.text-to-speech` queue with prefetch 1 and does not redeclare contract-owned queues. It reads `isi` from the existing event envelope and carries the correlation ID into the completion event.
- The MySQL `job` table has unique `puisi_id`, constrained status, attempt count, duration, and a lease token. Row locking protects concurrent workers. Audio uploads use deterministic `puisi_<id>.mp3` keys.
- Successful job state and the `audio.siap` event body are committed together in `event_outbox`. A publisher-confirm relay marks an event sent only after confirmation; an unconfirmed event remains eligible for retry.
- Transient failures are retried up to three total attempts with the shared `x-percobaan` header. Exhausted and malformed events go to the existing DLQ. Worker reconnect, graceful shutdown, and recovery through unacked redelivery and database leases are implemented.
- SeaweedFS has no host-published ports. Separate local identities scope worker access to the `audio` bucket, initialization privileges to that bucket, and anonymous access to read-only audio. The gateway accepts GET/HEAD for `/audio/`, denies PUT, returns MP3, and sets a one-day cache lifetime.

### I3 checks

| Check | Status | Result |
|---|---|---|
| Compose validation and service startup | PASS | Compose validation passed; MySQL, SeaweedFS, and both worker replicas reported healthy. |
| Event-to-audio flow | PASS | `scripts/kirim_event.py` published `puisi.dibuat`; job 1 reached `selesai`; `puisi_1.mp3` was stored (61,330 bytes, 7.863 seconds). |
| `audio.siap` contract | PASS | `q.tap` showed `puisi_id=1`, `/audio/puisi_1.mp3`, `durasi_detik=7.863`, and `mesin=piper-id_ID-news_tts-medium`. |
| Gateway audio response | PASS | GET/HEAD returned 200, `audio/mpeg`, 61,330 bytes, and a one-day cache header; PUT returned 403. |
| Duplicate event idempotency | PASS | The same event was sent three times total; the database retained one completed job, one canonical object, and one completion outbox event. |
| Malformed event and DLQ | PASS | Raw malformed input was rejected to `q.text-to-speech.dlq`. |
| Storage outage and three-attempt exhaustion | PASS | During a controlled SeaweedFS outage, job 41000 reached `gagal` with attempt count 3 and its message reached the DLQ. SeaweedFS was restored and healthy afterward. |
| Upload succeeded but DB completion failed | PASS (unit simulation) | Test verified the deterministic key is retained and the message is retried rather than acknowledged. |
| Outbox broker confirmation | PASS (unit simulation) | Confirmed publish marks the record; unconfirmed publish leaves it pending. |
| Full I2/I3 unit suite | PASS | `docker compose --profile tts run --rm --no-deps --entrypoint python text-to-speech -m unittest discover -s tests -v`; 16 tests passed. |

### Load measurements

Each measured run published 20 unique four-line poem events and waited for terminal job states. Environment: Windows Docker Desktop (`desktop-linux`), Python 3.12, Piper `id_ID-news_tts-medium`, SeaweedFS 4.53, MySQL 8.4, RabbitMQ 4.4.0. Only RabbitMQ node 1 was active and the queue had one quorum member, so these are local comparisons, not a production cluster benchmark.

| TTS replicas | Jobs completed | Drain time | Throughput |
|---:|---:|---:|---:|
| 2 | 20/20 | 21.266 s | 0.940 jobs/s |
| 4 | 20/20 | 16.357 s | 1.223 jobs/s |
| 4, repeat | 20/20 | 15.293 s | 1.308 jobs/s |

The four-replica runs were faster in these samples. A single `docker stats` snapshot during the repeat showed worker containers at 0.04–0.15% CPU, `tts-db` at 4.21%, SeaweedFS at 0.49%, and RabbitMQ at 0.84%. This is an instantaneous sample rather than peak utilization. The deployment was restored to two replicas afterward.

## Security review

- JWT, database, and S3 credentials are read from mounted secret files; no local secret file is tracked.
- Authentication and poem-service requests share the existing bearer-token helper without duplicate token storage. Auth requests omit cookie credentials; poem requests preserve their existing fetch behavior.
- Auth endpoint contains no PHP session state or auth cookie issuance. The legacy PHP file and unrelated poem functions remain intact.
- SQL uses prepared statements; passwords are hashed; poem text is passed to Piper over stdin; worker logs do not include credentials or poem contents.
- Gateway auth responses disable caching and login is rate limited. The audio gateway only permits GET/HEAD and routes to the audio bucket; SeaweedFS administrative/S3 ports are not host-published.
- Browser `localStorage` remains exposed to same-origin JavaScript and therefore to XSS. Browser-decoded token claims are for UI state only.

## Limitations and unrun checks

- Real browser-based auth login/reload/logout was not reported; frontend Node simulation passed.
- RabbitMQ node failover and three-node quorum membership were not verified in the TTS test environment; only node 1 was running.
- Live MySQL outage, worker process termination during synthesis, and live broker-confirm loss after completion publish were not exercised. The implementation includes persistence, retry, lease, and outbox handling, and the report identifies where only unit simulations were run.
- Verify the Indonesian model’s training-data license and pronunciation quality before redistribution or commercial deployment.

## Final delivery state

- I1 is committed and pushed to `ifham/layanan-auth` at `ff58195`.
- I2 and I3 are committed and pushed to `ifham/text-to-speech` at `2b8b00b` and `06ecabd`; the report location update is `004f62a`.
- The feature branches remain independent. `main` was not changed; no PR or merge was created.
