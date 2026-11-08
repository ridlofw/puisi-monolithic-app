<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/vendor/autoload.php';

use Puisi\Cache;
use Puisi\Jwt;
use Puisi\Konfig;
use Puisi\Log;
use Puisi\Metrik;
use Puisi\PuisiRepo;
use Puisi\Validasi;

$metode        = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$uri           = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$path          = rtrim($uri, '/') ?: '/';
$correlationId = $_SERVER['HTTP_X_REQUEST_ID'] ?? PuisiRepo::uuidV4();
$ruteMetrik    = preg_match('#^/api/puisi/\d+$#', $path) ? '/api/puisi/{id}' : $path;

if (empty($_SERVER['HTTP_X_REQUEST_ID'])) {
    header('X-Request-ID: ' . $correlationId);
}

if ($metode === 'GET' && ($path === '/metrics' || $path === '/api/puisi/metrics')) {
    header('Content-Type: text/plain; version=0.0.4; charset=utf-8');
    echo Metrik::teksHttp();
    exit;
}

header('Content-Type: application/json; charset=utf-8');

/**
 * @param mixed $data
 */
function balasJson(int $kodeHttp, string $status, string $pesan, $data = null): never
{
    global $metode, $ruteMetrik;
    Metrik::catatHttp($metode, $ruteMetrik, $kodeHttp);
    http_response_code($kodeHttp);
    $badan = [
        'status' => $status,
        'pesan'  => $pesan,
    ];
    if ($data !== null) {
        $badan['data'] = $data;
    }
    echo json_encode($badan, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/**
 * @return array<string, mixed>
 */
function bacaInputJson(): array
{
    $mentah = file_get_contents('php://input');
    if ($mentah === false || trim($mentah) === '') {
        return is_array($_POST) ? $_POST : [];
    }
    $decoded = json_decode($mentah, true);
    if (!is_array($decoded)) {
        balasJson(400, 'error', 'Body request harus berupa objek JSON yang sah.');
    }
    return $decoded;
}

function ambilHeaderAuth(): ?string
{
    $kandidat = [
        $_SERVER['HTTP_AUTHORIZATION'] ?? null,
        $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? null,
    ];
    foreach ($kandidat as $nilai) {
        if (is_string($nilai) && trim($nilai) !== '') {
            return $nilai;
        }
    }
    if (function_exists('getallheaders')) {
        foreach (getallheaders() as $k => $v) {
            if (strtolower((string) $k) === 'authorization' && is_string($v)) {
                return $v;
            }
        }
    }
    return null;
}

if ($metode === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// Endpoint pemeriksaan kesehatan container
if ($path === '/sehat' || $path === '/api/puisi/sehat') {
    balasJson(200, 'sukses', 'Layanan puisi sehat.');
}

try {
    // POST /api/puisi — kirim puisi baru dengan verifikasi JWT & transactional outbox
    if ($path === '/api/puisi' && $metode === 'POST') {
        $token = Jwt::ekstrakBearer(ambilHeaderAuth());
        if ($token === null) {
            balasJson(401, 'error', 'Token autentikasi (Bearer) wajib disertakan.');
        }

        try {
            $klaim = Jwt::verifikasi($token, Konfig::kunciJwt());
        } catch (\InvalidArgumentException $e) {
            balasJson(401, 'error', 'Token tidak sah: ' . $e->getMessage());
        }

        try {
            $input = Validasi::puisiBaru(bacaInputJson());
        } catch (\InvalidArgumentException $e) {
            balasJson(400, 'error', $e->getMessage());
        }

        $puisiId = PuisiRepo::simpanDenganOutbox($klaim, $input, $correlationId);
        Cache::invalidasi(null);

        Log::info('puisi disimpan ke database dan outbox', [
            'correlation_id' => $correlationId,
            'puisi_id'       => $puisiId,
            'penulis'        => $klaim['nama'],
        ]);

        balasJson(202, 'sukses', 'Puisi diterima dan sedang diproses.', [
            'id'     => $puisiId,
            'status' => 'diproses',
        ]);
    }

    // GET /api/puisi — galeri publik dengan Cache-Aside Redis (TTL 60 detik)
    if ($path === '/api/puisi' && $metode === 'GET') {
        $hal    = isset($_GET['hal']) ? max(1, (int) $_GET['hal']) : 1;
        $perHal = isset($_GET['per_hal']) ? max(1, min(50, (int) $_GET['per_hal'])) : 12;

        $dariCache = Cache::ambilGaleri($hal, $perHal);
        if ($dariCache !== null) {
            Metrik::catatCache(true);
            header('X-Cache-Layer: redis');
            balasJson(200, 'sukses', 'Daftar puisi berhasil dimuat.', $dariCache);
        }

        Metrik::catatCache(false);
        $daftar = PuisiRepo::daftar($hal, $perHal);
        Cache::simpanGaleri($hal, $daftar, 60, $perHal);
        header('X-Cache-Layer: db');
        balasJson(200, 'sukses', 'Daftar puisi berhasil dimuat.', $daftar);
    }

    // GET /api/puisi/{id} — detail satu puisi dengan Cache-Aside Redis (TTL 60 detik)
    if (preg_match('#^/api/puisi/(\d+)$#', $path, $cocok) && $metode === 'GET') {
        $id        = (int) $cocok[1];
        $dariCache = Cache::ambilDetail($id);
        if ($dariCache !== null) {
            Metrik::catatCache(true);
            header('X-Cache-Layer: redis');
            balasJson(200, 'sukses', 'Detail puisi berhasil dimuat.', $dariCache);
        }

        Metrik::catatCache(false);
        $detail = PuisiRepo::detail($id);
        if ($detail === null) {
            balasJson(404, 'error', 'Puisi tidak ditemukan.');
        }
        Cache::simpanDetail($id, $detail, 60);
        header('X-Cache-Layer: db');
        balasJson(200, 'sukses', 'Detail puisi berhasil dimuat.', $detail);
    }

    if ($path === '/api/puisi' || preg_match('#^/api/puisi/\d+$#', $path)) {
        balasJson(405, 'error', 'Metode HTTP tidak diizinkan untuk rute ini.');
    }

    balasJson(404, 'error', 'Rute tidak ditemukan.');
} catch (\PDOException $e) {
    Log::error('kegagalan basis data pada poem-service', [
        'correlation_id' => $correlationId,
        'error'          => $e->getMessage(),
    ]);
    balasJson(503, 'error', 'Layanan basis data sedang tidak tersedia.');
} catch (\Throwable $e) {
    Log::error('kegagalan internal pada poem-service', [
        'correlation_id' => $correlationId,
        'error'          => $e->getMessage(),
    ]);
    balasJson(500, 'error', 'Terjadi kesalahan pada layanan puisi.');
}
