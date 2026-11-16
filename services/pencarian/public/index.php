<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/vendor/autoload.php';

use Pencarian\Konfig;
use Pencarian\OpenSearch;
use Pencarian\QueryBuilder;

header('Content-Type: application/json; charset=utf-8');

function balas(int $kode, string $status, string $pesan, array $tambahan = []): never
{
    http_response_code($kode);
    echo json_encode(['status' => $status, 'pesan' => $pesan] + $tambahan, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

$metode = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path   = rtrim(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/', '/') ?: '/';

$os = new OpenSearch();

if ($path === '/sehat' && $metode === 'GET') {
    try {
        [$kode] = $os->minta('GET', '/_cluster/health');
        $kode === 200 ? balas(200, 'sukses', 'Search service sehat.') : balas(503, 'error', 'OpenSearch belum siap.');
    } catch (\Throwable) {
        balas(503, 'error', 'OpenSearch tidak terjangkau.');
    }
}

if ($path !== '/api/search') {
    balas(404, 'error', 'Rute tidak ditemukan.');
}
if ($metode !== 'GET') {
    header('Allow: GET');
    balas(405, 'error', 'Method tidak diizinkan. Gunakan GET.');
}

$param = static function (string $k): string {
    $v = $_GET[$k] ?? '';
    if (!is_string($v)) {
        balas(400, 'error', "Parameter $k harus berupa teks tunggal.");
    }
    return $v;
};

try {
    $badan = QueryBuilder::bangun($param('q'), $param('genre'), $param('tag'), $param('hal'));
} catch (\InvalidArgumentException $e) {
    balas(400, 'error', $e->getMessage());
}

try {
    [$kode, $respons] = $os->minta('POST', '/' . Konfig::INDEKS . '/_search', $badan);
    if ($kode === 404) {
        // indeks belum ada: belum ada puisi yang bisa dicari, bukan kesalahan
        $respons = [];
    } elseif ($kode !== 200) {
        throw new \RuntimeException('OpenSearch menjawab HTTP ' . $kode);
    }
} catch (\Throwable $e) {
    error_log('search gagal: ' . $e->getMessage() . ' rid=' . preg_replace('/[^A-Za-z0-9._-]/', '', $_SERVER['HTTP_X_REQUEST_ID'] ?? '-'));
    balas(503, 'error', 'Layanan pencarian sementara tidak tersedia.');
}

$hasil = QueryBuilder::hasil($respons);
header('X-Cache-Layer: opensearch');
balas(200, 'sukses', 'Pencarian selesai.', [
    'data'  => $hasil['data'],
    'total' => $hasil['total'],
    'hal'   => QueryBuilder::halaman($param('hal')),
]);
