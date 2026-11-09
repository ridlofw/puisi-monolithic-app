# Auth service

The service owns registration and login at `POST /api/auth/register` and `POST /api/auth/login`. It stores password hashes in its private MySQL 8.4 database and issues one-hour HS256 JWTs. It does not use PHP sessions or authentication cookies. `services/puisi/src/Jwt.php` remains the token verification contract.

## Local startup

From the repository root, create local secrets and start the profile:

```sh
python scripts/siapkan_rahasia.py
python scripts/siapkan_rahasia_auth.py
docker compose --profile auth up -d --build
docker compose ps auth-db auth-service
```

`secrets/jwt_secret.txt` is shared by every replica. `secrets/auth_db_password.txt` is shared by both auth replicas and MySQL's app user; `secrets/auth_db_root_password.txt` is mounted only in MySQL. All are ignored by Git. If the database was initialized before credentials were provisioned, changing files does not change the existing MySQL accounts; update the local accounts or recreate the auth volume only when it contains no needed data.

The Compose fragment declares `deploy.replicas: 2`. Confirm two running containers with `docker compose ps -q auth-service`; both use the same Compose network service name, database, and JWT secret.

## API

Responses use the shared `{status, pesan, data}` envelope. Registration requires non-empty `username`, `password`, `nama`, and `no_id`; field lengths match the legacy schema. Passwords must be 8–72 bytes. Duplicate usernames return 409. Login returns `{token, user:{id,username,nama}}`; invalid credentials return 401. The gateway rate-limits login requests and auth responses are marked `Cache-Control: no-store`.

The frontend stores the bearer token in `localStorage` under `puisi.token`, using shared helpers from `web/js/api.js`. Auth requests omit browser credentials; poem requests retain their existing fetch behavior. `localStorage` allows JavaScript access and increases the impact of XSS. Browser-decoded claims control UI state only and are never authorization evidence.

## Tests

```sh
composer install --working-dir=services/auth
services/auth/vendor/bin/phpunit -c services/auth/phpunit.xml
python services/auth/tests/integration.py
```

The PHPUnit JWT test compares the issued token byte-for-byte with `kontrak/jwt-vektor.json` and passes it to the poem service's verifier. The live integration test requires the auth profile and gateway running; it checks required-field validation, registration, duplicates, wrong password, ten logins without `Set-Cookie`, and verifies a returned token inside both running replicas.
