"""Live auth flow and cross-replica checks; run with the auth Compose profile up."""
import json
import os
import subprocess
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get('AUTH_BASE_URL', 'http://localhost').rstrip('/')


def request(path, body):
    payload = json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=payload, headers={'Content-Type': 'application/json'})
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    return response.status, response.headers, json.loads(response.read())


def main():
    suffix = uuid.uuid4().hex[:12]
    user = {'username': 'codex_' + suffix, 'password': 'a-strong-test-password', 'nama': 'Pengguna Uji', 'no_id': suffix}
    empty_status, _, _ = request('/api/auth/register', {})
    assert empty_status == 400, empty_status

    status, _, body = request('/api/auth/register', user)
    assert status == 201 and body['status'] == 'sukses', (status, body)
    duplicate_status, _, _ = request('/api/auth/register', user)
    assert duplicate_status == 409, duplicate_status

    wrong = dict(user, password='incorrect-password')
    wrong_status, _, _ = request('/api/auth/login', {'username': user['username'], 'password': wrong['password']})
    assert wrong_status == 401, wrong_status

    tokens = []
    results = []
    for _ in range(10):
        login_status, headers, login = request('/api/auth/login', {'username': user['username'], 'password': user['password']})
        assert 'Set-Cookie' not in headers, dict(headers)
        assert login_status in (200, 429), (login_status, login)
        if login_status == 200:
            assert login.get('data', {}).get('token'), login
            tokens.append(login['data']['token'])
        else:
            assert login.get('status') == 'error' and 'pesan' in login, login
        results.append(login_status)
    assert tokens, f'no successful login in results: {results}'
    ids = subprocess.check_output(['docker', 'compose', 'ps', '-q', 'auth-service'], text=True).split()
    if len(ids) < 2 or len(set(ids)) < 2:
        raise AssertionError(f'expected two running auth replicas, found {len(ids)}')
    token = tokens[-1]
    for container_id in ids:
        code = "require '/var/www/html/src/Jwt.php'; require '/var/www/html/src/Db.php'; Auth\\Jwt::verify($argv[1], Auth\\Db::readSecret('/run/secrets/jwt_secret')); $q=Auth\\Db::connect()->prepare('SELECT id FROM users WHERE username = ?'); $q->execute([$argv[2]]); if (!$q->fetch()) exit(1); echo \"verified\\n\";"
        subprocess.run(['docker', 'exec', container_id, 'php', '-r', code, token, user['username']], check=True)
    print(f'PASS: empty validation, register, duplicate, wrong password, 10 cookie-free logins {results}, two-replica token verification')


if __name__ == '__main__':
    main()
