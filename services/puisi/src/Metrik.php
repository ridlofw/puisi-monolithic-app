<?php
declare(strict_types=1);

namespace Puisi;

final class Metrik
{
    private const HASH_HTTP  = 'puisi:metrik:http';
    private const HASH_CACHE = 'puisi:metrik:cache';
    private const BATAS      = [0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0];

    /** @var array<string, int> */
    private static array $lokalHttp = [];

    /** @var array<string, int> */
    private static array $lokalCache = ['hit' => 0, 'miss' => 0];

    private static int $workerDiproses = 0;
    private static int $workerGagal    = 0;

    /** @var list<int> */
    private static array $workerEmber = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    private static float $workerJumlahDurasi = 0.0;
    private static int $workerHitungDurasi   = 0;

    /** @var resource|false|null */
    private static $prosesServer = null;

    public static function catatHttp(string $metode, string $rute, int $status): void
    {
        $field = "{$metode}|{$rute}|{$status}";
        self::$lokalHttp[$field] = (self::$lokalHttp[$field] ?? 0) + 1;
        Cache::hIncrBy(self::HASH_HTTP, $field, 1);
    }

    public static function catatCache(bool $hit): void
    {
        $kunci = $hit ? 'hit' : 'miss';
        self::$lokalCache[$kunci] = (self::$lokalCache[$kunci] ?? 0) + 1;
        Cache::hIncrBy(self::HASH_CACHE, $kunci, 1);
    }

    public static function teksHttp(): string
    {
        $baris = [
            '# HELP puisi_http_requests_total Total permintaan HTTP pada poem-service.',
            '# TYPE puisi_http_requests_total counter',
        ];

        $dataHttp = Cache::hGetAll(self::HASH_HTTP);
        if ($dataHttp === []) {
            foreach (self::$lokalHttp as $k => $v) {
                $dataHttp[$k] = (string) $v;
            }
        }
        if ($dataHttp === []) {
            $baris[] = 'puisi_http_requests_total{method="GET",route="/api/puisi",status="200"} 0';
        } else {
            ksort($dataHttp);
            foreach ($dataHttp as $field => $nilai) {
                [$metode, $rute, $status] = array_pad(explode('|', (string) $field, 3), 3, '');
                $jml = (int) $nilai;
                $baris[] = sprintf(
                    'puisi_http_requests_total{method="%s",route="%s",status="%s"} %d',
                    addslashes($metode),
                    addslashes($rute),
                    addslashes($status),
                    $jml
                );
            }
        }

        $dataCache = Cache::hGetAll(self::HASH_CACHE);
        $hits      = isset($dataCache['hit']) ? (int) $dataCache['hit'] : (self::$lokalCache['hit'] ?? 0);
        $misses    = isset($dataCache['miss']) ? (int) $dataCache['miss'] : (self::$lokalCache['miss'] ?? 0);

        $baris[] = '# HELP puisi_cache_hits_total Total pembacaan cache Redis yang HIT.';
        $baris[] = '# TYPE puisi_cache_hits_total counter';
        $baris[] = "puisi_cache_hits_total {$hits}";
        $baris[] = '# HELP puisi_cache_misses_total Total pembacaan cache Redis yang MISS.';
        $baris[] = '# TYPE puisi_cache_misses_total counter';
        $baris[] = "puisi_cache_misses_total {$misses}";

        $tertunda = PuisiRepo::hitungOutboxTertunda();
        $baris[]  = '# HELP puisi_outbox_pending Jumlah baris outbox yang belum diterbitkan ke RabbitMQ.';
        $baris[]  = '# TYPE puisi_outbox_pending gauge';
        $baris[]  = "puisi_outbox_pending {$tertunda}";

        return implode("\n", $baris) . "\n";
    }

    public static function mulaiServerDaemon(string $worker, string $queue, int $port = 9100): void
    {
        self::tulisFileMetrikWorker($worker, $queue);
        $skrip = dirname(__DIR__) . '/bin/metrik_server.php';
        if (!is_file($skrip)) {
            return;
        }
        $cmd = sprintf('php -S 0.0.0.0:%d %s >/dev/null 2>&1', $port, escapeshellarg($skrip));
        $spec = [
            0 => ['pipe', 'r'],
            1 => ['file', '/dev/null', 'a'],
            2 => ['file', '/dev/null', 'a'],
        ];
        self::$prosesServer = @proc_open($cmd, $spec, $pipes);
    }

    public static function catatWorker(string $worker, string $queue, bool $sukses, float $durasi): void
    {
        if ($sukses) {
            self::$workerDiproses++;
        } else {
            self::$workerGagal++;
        }
        foreach (self::BATAS as $i => $batas) {
            if ($durasi <= $batas) {
                self::$workerEmber[$i]++;
            }
        }
        self::$workerJumlahDurasi += $durasi;
        self::$workerHitungDurasi++;
        self::tulisFileMetrikWorker($worker, $queue);
    }

    private static function tulisFileMetrikWorker(string $worker, string $queue): void
    {
        $label = sprintf('worker="%s",queue="%s"', addslashes($worker), addslashes($queue));
        $baris = [
            '# HELP worker_pesan_diproses_total Pesan yang selesai diproses dan di-ack.',
            '# TYPE worker_pesan_diproses_total counter',
            sprintf('worker_pesan_diproses_total{%s} %d', $label, self::$workerDiproses),
            '# HELP worker_pesan_gagal_total Percobaan yang gagal dan dikembalikan ke queue.',
            '# TYPE worker_pesan_gagal_total counter',
            sprintf('worker_pesan_gagal_total{%s} %d', $label, self::$workerGagal),
            '# HELP worker_durasi_detik Lama pemrosesan satu pesan.',
            '# TYPE worker_durasi_detik histogram',
        ];
        foreach (self::BATAS as $i => $batas) {
            $baris[] = sprintf('worker_durasi_detik_bucket{%s,le="%s"} %d', $label, (string) $batas, self::$workerEmber[$i]);
        }
        $baris[] = sprintf('worker_durasi_detik_bucket{%s,le="+Inf"} %d', $label, self::$workerHitungDurasi);
        $baris[] = sprintf('worker_durasi_detik_sum{%s} %.6f', $label, self::$workerJumlahDurasi);
        $baris[] = sprintf('worker_durasi_detik_count{%s} %d', $label, self::$workerHitungDurasi);

        $isi = implode("\n", $baris) . "\n";
        @file_put_contents('/tmp/metrik.prom', $isi);
    }
}

