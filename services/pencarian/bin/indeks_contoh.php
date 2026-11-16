<?php
declare(strict_types=1);

//Mengindeks data/contoh.json langsung ke OpenSearch, hanya untuk pengujian E1.
require_once dirname(__DIR__) . '/vendor/autoload.php';

use Pencarian\Indeks;
use Pencarian\Konfig;
use Pencarian\OpenSearch;

$os = new OpenSearch();
Indeks::pastikan($os);
$daftar = json_decode((string) file_get_contents(dirname(__DIR__) . '/data/contoh.json'), true, 512, JSON_THROW_ON_ERROR);
foreach ($daftar as $p) {
    $id = (int) $p['id'];
    unset($p['id']);
    [$kode] = $os->minta('PUT', '/' . Konfig::INDEKS . '/_doc/' . $id . '?refresh=true', $p);
    fwrite(STDOUT, "puisi $id: HTTP $kode" . PHP_EOL);
}
