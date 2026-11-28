<?php
declare(strict_types=1);

namespace Pencarian;

//Cache-aside hasil pencarian di Redis. Redis yang mati tidak pernah menggagalkan pencarian.
 //Key: cari:v{versi}:{sha1 parameter}. Consumer menaikkan cari:versi dengan INCR setiap indeks berubah, jadi semua key lama otomatis tidak terbaca lagi tanpa dihapus satu per satu (TTL 120 detik membersihkannya).

final class Cache
{
    public const KUNCI_VERSI = 'cari:versi';
    public const TTL         = 120;

    private static ?\Redis $klien = null;
    private static float $gagalTerakhir = 0.0;
    private static bool $pakaiPemutus = false;

    private const JEDA_PEMUTUS = 10; // detik Redis dilewati setelah gagal sambung (hanya request web)

    public static function kunci(int $versi, array $param): string
    {
        if (isset($param['q']) && is_string($param['q'])) {
            $param['q'] = mb_strtolower($param['q']); // analyzer OpenSearch tidak membedakan huruf besar kecil
        }
        ksort($param);
        return 'cari:v' . $versi . ':' . sha1(json_encode($param, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }

    //null bila Redis tidak tersedia (pencarian lalu jalan tanpa cache)
    public static function versi(): ?int
    {
        return self::coba(static function (\Redis $r): int {
            $v = $r->get(self::KUNCI_VERSI);
            // key belum ada (Redis baru menyala atau baru dikosongkan) dihitung 0, bukan 1. INCR pertama membuat
            // key bernilai 1, jadi versi berubah dan semua hasil lama langsung tidak terpakai
            return (is_string($v) && ctype_digit($v)) ? (int) $v : 0;
        });
    }

    public static function ambil(string $kunci): ?array
    {
        return self::coba(static function (\Redis $r) use ($kunci): ?array {
            $mentah = $r->get($kunci);
            if (!is_string($mentah) || $mentah === '') {
                return null;
            }
            $data = json_decode($mentah, true);
            return is_array($data) ? $data : null;
        });
    }

    public static function simpan(string $kunci, array $nilai): void
    {
        $json = json_encode($nilai, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($json === false) {
            return;
        }
        self::coba(static function (\Redis $r) use ($kunci, $json): bool {
            return (bool) $r->setex($kunci, self::TTL, $json);
        });
    }

    public const TTL_BASI = 1800;

    //Salinan cadangan tanpa versi, hanya disajikan saat OpenSearch tidak tersedia (degradasi halus, Bab 11.2)
    public static function kunciBasi(array $param): string
    {
        return 'cari:basi:' . substr(self::kunci(0, $param), strlen('cari:v0:'));
    }

    public static function simpanBasi(array $param, array $nilai): void
    {
        $json = json_encode($nilai, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($json === false) {
            return;
        }
        $kunci = self::kunciBasi($param);
        self::coba(static fn (\Redis $r): bool => (bool) $r->setex($kunci, self::TTL_BASI, $json));
    }

    public static function ambilBasi(array $param): ?array
    {
        return self::ambil(self::kunciBasi($param));
    }

    //Dipanggil consumer setelah indeks berubah. @return bool false bila Redis tidak terjangkau
    public static function naikkanVersi(): bool
    {
        // paksa: jangan dilewati karena jeda gagal. Menaikkan versi yang terlewat berarti hasil basi tetap disajikan
        return self::coba(static fn(\Redis $r): bool => $r->incr(self::KUNCI_VERSI) !== false, true) === true;
    }

    /** Dipanggil sekali oleh index.php: request web mengingat Redis mati lewat berkas, supaya tidak menunggu DNS tiap request. */
    public static function aktifkanPemutus(): void
    {
        self::$pakaiPemutus = true;
    }

    private static function coba(callable $kerja, bool $paksa = false): mixed
    {
        for ($ulang = 0; $ulang < 2; $ulang++) {
            $r = self::klien($paksa);
            if ($r === null) {
                return null;
            }
            try {
                return $kerja($r);
            } catch (\Throwable $e) {
                self::lepas();
                // READONLY: node ini master lama yang sudah diturunkan Sentinel, cari master baru lalu ulangi sekali
                if (!str_starts_with($e->getMessage(), 'READONLY')) {
                    self::$gagalTerakhir = microtime(true);
                    return null;
                }
            }
        }
        return null;
    }

    private static function penemu(): MasterRedis
    {
        // env dibaca setiap kali seperti sebelumnya; ingatan master ada di berkas, bukan di objek ini
        $hosts    = array_values(array_filter(array_map('trim', explode(',', Konfig::env('REDIS_HOSTS', 'redis:6379')))));
        $sentinel = array_values(array_filter(array_map('trim', explode(',', Konfig::env('REDIS_SENTINELS', '')))));
        // nama berkas mengikuti konfigurasi, supaya alamat tersimpan dari konfigurasi lain tidak terpakai
        $berkas = sys_get_temp_dir() . '/pencarian-redis-' . substr(md5(json_encode([$hosts, $sentinel])), 0, 8) . '.json';
        return new MasterRedis($hosts, $sentinel, Konfig::env('REDIS_MASTER_NAME', 'puisi'), $berkas);
    }

    private static function lepas(): void
    {
        self::$klien = null;
        self::penemu()->lupakan();
    }

    private static function berkasPemutus(): string
    {
        return sys_get_temp_dir() . '/pencarian-redis-mati';
    }

    /** Redis baru saja gagal, jadi jangan menunggu lagi untuk sementara. */
    private static function sedangMati(): bool
    {
        if ((microtime(true) - self::$gagalTerakhir) < 2.0) {
            return true; // dalam satu proses (consumer berjalan lama)
        }
        if (!self::$pakaiPemutus) {
            return false;
        }
        // Setiap request web adalah proses baru. Menyambung ke host Redis yang sudah hilang dari DNS Docker
        // bisa memakan beberapa detik, jadi kegagalan diingat lintas request lewat berkas penanda
        $berkas = self::berkasPemutus();
        clearstatcache(true, $berkas);
        $waktu = @filemtime($berkas);
        return $waktu !== false && (time() - $waktu) < self::JEDA_PEMUTUS;
    }

    private static function klien(bool $paksa = false): ?\Redis
    {
        if (!class_exists(\Redis::class)) {
            return null;
        }
        if (self::$klien !== null) {
            return self::$klien;
        }
        if (!$paksa && self::sedangMati()) {
            return null;
        }
        $hasil = self::penemu()->cari($paksa);
        if ($hasil !== null && $hasil[0] instanceof \Redis) {
            if (self::$pakaiPemutus) {
                @unlink(self::berkasPemutus());
            }
            return self::$klien = $hasil[0];
        }
        self::$gagalTerakhir = microtime(true);
        if (self::$pakaiPemutus) {
            @touch(self::berkasPemutus());
        }
        return null;
    }
}
