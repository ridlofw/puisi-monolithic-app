<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/src/Db.php';
require_once dirname(__DIR__) . '/src/Jwt.php';

use Auth\Db;
use Auth\Jwt;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function respond(int $code, string $status, string $message, mixed $data = null): never
{
    http_response_code($code);
    $body = ['status' => $status, 'pesan' => $message];
    if ($data !== null) {
        $body['data'] = $data;
    }
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

$path = rtrim(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/', '/') ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($path === '/sehat' && $method === 'GET') {
    try {
        Db::connect()->query('SELECT 1');
        Db::readSecret(getenv('JWT_SECRET_FILE') ?: '/run/secrets/jwt_secret');
        respond(200, 'sukses', 'Auth service sehat.');
    } catch (\Throwable) {
        respond(503, 'error', 'Auth service belum siap.');
    }
}

if ($method !== 'POST') {
    header('Allow: POST');
    respond(405, 'error', 'Method tidak diizinkan. Gunakan POST.');
}

if (!in_array($path, ['/api/auth/register', '/api/auth/login'], true)) {
    respond(404, 'error', 'Rute tidak ditemukan.');
}

$raw = file_get_contents('php://input');
$input = is_string($raw) ? json_decode($raw, true) : null;
if (!is_array($input)) {
    respond(400, 'error', 'Body request harus berupa objek JSON yang sah.');
}

try {
    $pdo = Db::connect();
    if ($path === '/api/auth/register') {
        $username = is_string($input['username'] ?? null) ? trim($input['username']) : '';
        $password = is_string($input['password'] ?? null) ? $input['password'] : '';
        $name = is_string($input['nama'] ?? null) ? trim($input['nama']) : '';
        $idNumber = is_string($input['no_id'] ?? null) ? trim($input['no_id']) : '';
        if ($username === '' || $password === '' || $name === '' || $idNumber === '') {
            respond(400, 'error', 'Semua field wajib diisi (username, password, nama, no_id).');
        }
        if (mbLen($username) > 50 || mbLen($name) > 100 || mbLen($idNumber) > 50
            || strlen($password) < 8 || strlen($password) > 72) {
            respond(400, 'error', 'Panjang field tidak valid. Password harus 8 sampai 72 byte.');
        }
        try {
            $statement = $pdo->prepare('INSERT INTO users (username, password, nama, no_id) VALUES (?, ?, ?, ?)');
            $statement->execute([$username, password_hash($password, PASSWORD_DEFAULT), $name, $idNumber]);
        } catch (\PDOException $e) {
            if ($e->getCode() === '23000') {
                respond(409, 'error', 'Username sudah terdaftar. Gunakan username lain.');
            }
            throw $e;
        }
        respond(201, 'sukses', 'Registrasi berhasil. Silakan login.');
    }

    $username = is_string($input['username'] ?? null) ? trim($input['username']) : '';
    $password = is_string($input['password'] ?? null) ? $input['password'] : '';
    if ($username === '' || $password === '') {
        respond(400, 'error', 'Username dan password wajib diisi.');
    }
    $statement = $pdo->prepare('SELECT id, username, nama, password FROM users WHERE username = ? LIMIT 1');
    $statement->execute([$username]);
    $user = $statement->fetch();
    if (!is_array($user) || !password_verify($password, $user['password'])) {
        respond(401, 'error', 'Username atau password salah.');
    }
    $secret = Db::readSecret(getenv('JWT_SECRET_FILE') ?: '/run/secrets/jwt_secret');
    $token = Jwt::issue($user, $secret);
    respond(200, 'sukses', 'Login berhasil.', [
        'token' => $token,
        'user' => ['id' => (int) $user['id'], 'username' => $user['username'], 'nama' => $user['nama']],
    ]);
} catch (\Throwable) {
    error_log('Auth request failed; request_id=' . preg_replace('/[^A-Za-z0-9._-]/', '', $_SERVER['HTTP_X_REQUEST_ID'] ?? 'unknown'));
    respond(503, 'error', 'Layanan autentikasi sementara tidak tersedia.');
}

function mbLen(string $value): int
{
    return function_exists('mb_strlen') ? mb_strlen($value, 'UTF-8') : strlen($value);
}
