# Implementation and test report — I1 auth service

## Repository and branch

- Repository root: D:/codes/testing/scalable-2/text-to-speech/puisi-monolithic-app-main
- Branch: ifham/layanan-auth
- Starting commit: 2d0e1e88906caaa2dc64eb3d8b33273ee4827ef3
- Remote: origin → https://github.com/ridlofw/puisi-monolithic-app.git
- main and ifham/text-to-speech were not changed. No push or PR was created.

## ZIP reconciliation

text-to-speech.zip contains 143 files and has no paths missing from the workspace. Comparing ZIP contents with git show HEAD:<path> found all 143 files identical to the repository baseline. Raw comparisons against the Windows checkout showed line-ending differences; these were not treated as content changes. kontrak/README.md, web/js/api.js, web/js/auth.js, web/js/galeri.js, web/js/kirim.js, web/js/pencarian.js, web/index.html, and web/style.css were inspected. No ZIP files were extracted or copied over the repository.

## Architecture and implementation

- legacy/server.php remains unchanged, including its historical PHP session implementation and non-authentication poem actions. The active frontend auth flow now uses /api/auth/; poem frontend requests already target /api/puisi and continue to use the shared bearer-token helper.
- The auth service uses prepared MySQL statements, password_hash / password_verify, validation, duplicate-user HTTP 409 handling, and a shared MySQL 8.4 database.
- Auth has no PHP session calls or cookie issuance. Login issues an ordered HS256 token with a one-hour lifetime. The signing key is read from /run/secrets/jwt_secret.
- compose/auth.yaml configures two auth replicas, one database, shared app-password/JWT secrets, health checks, and readiness dependency. docker compose config resolves deploy.replicas to 2.
- The gateway routes /api/auth/, disables caching, and rate-limits login to 10 requests per minute with a burst of 5. Throttle responses use the shared JSON envelope.
- Frontend token storage uses the existing puisi.token key and helpers in api.js. Auth requests omit browser credentials; poem requests retain credentials: include. Browser claims control presentation only. localStorage has an XSS exposure, documented in the README.
- Local secret generators create JWT and DB secrets without overwriting existing secret files. No secret values were generated or committed during this implementation.

## Files changed

- Added services/auth/ service, schema, PHP/JWT tests, live integration script, and setup documentation.
- Updated compose/auth.yaml, gateway/nginx.conf, and added gateway/rute/auth.conf.
- Updated web/js/api.js, web/js/auth.js, root README.md, and .gitignore.
- Added scripts/siapkan_rahasia_auth.py.
- Added this report.

## I1 test results

| Check | Status | Result |
|---|---|---|
| PHPUnit JWT contract vector exact match | PASS | Issued token matched kontrak/jwt-vektor.json byte-for-byte; poem-service Jwt::verifikasi accepted it. |
| PHPUnit JWT lifetime and claim order | PASS | One-hour default lifetime and ordered claims asserted. |
| Auth code has no PHP session or cookie calls | PASS | PHPUnit source check; runtime HTTP behavior still needs the live integration test. |
| Frontend login, reload, logout and token expiry handling | PASS | Node simulation passed using the shared JWT vector. |
| Auth requests omit credentials; poem requests preserve existing behavior | PASS | Node simulation verified omit for auth and include plus bearer header for poem calls. |
| PHP lint, JS syntax, Python compile | PASS | All service PHP files, frontend files, and test/setup Python files checked. |
| Composer validation and platform requirements | PASS | Valid manifest; PHP 8.5 local platform requirements satisfied. Composer reported only the optional missing-license warning. |
| Compose config and replica/secret/database settings | PASS | Config validation succeeded; auth replicas resolve to 2, DB host to auth-db, image to MySQL 8.4, and the JWT secret is mounted. |
| Empty fields → HTTP 400; registration → 201; duplicate → 409; wrong password → 401 | BLOCKED | Live HTTP integration requires Docker services, which could not start. Tests are implemented in services/auth/tests/integration.py. |
| Successful login, no Set-Cookie, and ten login responses | BLOCKED | Live HTTP integration requires the unavailable Docker engine. |
| Runtime authentication across two replicas | BLOCKED | Integration test checks the issued token and registered user from both replicas; unable to run without Docker. |
| Browser login/reload/logout in a real browser | NOT RUN | A Node browser-API simulation passed; no browser-backed service was available. |
| Secret mounts and service health at runtime | BLOCKED | Compose declaration validated, but containers could not start. |

Commands run included:

    services/auth/vendor/bin/phpunit -c services/auth/phpunit.xml
    node services/auth/tests/frontend.test.js
    python services/auth/tests/integration.py
    docker compose --profile auth config --quiet
    docker compose --profile auth config --format json
    docker compose --profile auth up -d --build auth-service

The final docker compose up attempt failed because Docker Desktop’s Linux engine was unavailable (dockerDesktopLinuxEngine named pipe not found). Running the live integration script then received connection refused from localhost:80. Therefore no successful container start or live HTTP result is claimed.

## I2 and I3

NOT RUN in this session. This work remained scoped to I1 on ifham/layanan-auth.

## Security review and limitations

- No JWT or database secret was hardcoded. The signing and DB passwords are Docker secrets sourced from ignored secrets/ files.
- Registration and login use prepared statements; password values are hashed and are not logged. Error logs include only a sanitized request ID.
- Gateway login rate limiting and no-store response handling are configured. The frontend does not treat decoded claims as authorization evidence.
- The legacy app still contains its original session-based paths by design; its non-auth poem functionality was preserved and it was not edited.
- Live database behavior, actual replica count, gateway rate limiting, real browser interaction, and Set-Cookie behavior remain unverified until Docker is available.
- The implementation and this report are included in the I1 branch commit. No push was made.
