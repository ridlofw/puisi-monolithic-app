<?php
declare(strict_types=1);

//Dijalankan sekali saat container start. Menunggu OpenSearch, lalu membuat indeks bila belum ada.
require_once dirname(__DIR__) . '/vendor/autoload.php';

use Pencarian\Indeks;
use Pencarian\OpenSearch;

$os = new OpenSearch();
for ($i = 1; $i <= 60; $i++) {
    try {
        $dibuat = Indeks::pastikan($os);
        fwrite(STDOUT, ($dibuat ? 'indeks puisi dibuat' : 'indeks puisi sudah ada') . PHP_EOL);
        exit(0);
    } catch (\Throwable $e) {
        fwrite(STDERR, "menunggu OpenSearch ($i/60): " . $e->getMessage() . PHP_EOL);
        sleep(2);
    }
}
fwrite(STDERR, 'menyerah menunggu OpenSearch, service tetap dijalankan' . PHP_EOL);
exit(0);
