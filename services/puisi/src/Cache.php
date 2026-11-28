<?php
declare(strict_types=1);

namespace Puisi;

final class Cache
{
    private const KUNCI_VERSI_GALERI = 'puisi:galeri:versi';
    private static ?\Redis $klien = null;
    private static float $waktuGagalTerakhir = 0.0;

    private static function klien(): ?\Redis
    {
        if (!class_exists(\Redis::class)) {
            return null;
        }

        if (self::$klien instanceof \Redis) {
            try {
                if (self::$klien->isConnected()) {
                    return self::$klien;
                }
            } catch (\Throwable) {
                self::$klien = null;
            }
        }

        // Hindari mencoba sambung berulang-ulang pada request yang sama saat Redis sedang mati
        if ((microtime(true) - self::$waktuGagalTerakhir) < 2.0) {
            return null;
        }

        $hasil = self::penemu()->cari();
        if ($hasil !== null && $hasil[0] instanceof \Redis) {
            self::$klien = $hasil[0];
            return self::$klien;
        }

        // Tidak ada node Redis yang terjangkau: degradasi ke DB
        self::$waktuGagalTerakhir = microtime(true);
        return null;
    }

    private static function penemu(): MasterRedis
    {
        // env dibaca setiap kali seperti sebelumnya; ingatan master ada di berkas, bukan di objek ini
        $hosts    = Konfig::daftarHostRedis();
        $sentinel = Konfig::daftarSentinelRedis();
        // nama berkas mengikuti konfigurasi, supaya alamat tersimpan dari konfigurasi lain tidak terpakai
        $berkas = sys_get_temp_dir() . '/puisi-redis-' . substr(md5(json_encode([$hosts, $sentinel])), 0, 8) . '.json';
        return new MasterRedis($hosts, $sentinel, Konfig::namaMasterRedis(), $berkas);
    }

    /** Koneksi rusak, atau penulisan ditolak READONLY (phpredis melempar RedisException): cari master lagi. */
    private static function lepas(): void
    {
        self::$klien = null;
        self::penemu()->lupakan();
    }

    private static function kunciGaleri(\Redis $r, int $hal, int $perHal = 12): string
    {
        $versiMentah = $r->get(self::KUNCI_VERSI_GALERI);
        $versi       = ($versiMentah !== false && is_numeric($versiMentah)) ? (int) $versiMentah : 1;
        if ($perHal === 12) {
            return "puisi:galeri:v{$versi}:hal:{$hal}";
        }
        return "puisi:galeri:v{$versi}:hal:{$hal}:per:{$perHal}";
    }

    /**
     * @return ?list<array<string, mixed>>
     */
    public static function ambilGaleri(int $hal, int $perHal = 12): ?array
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return null;
            }
            $mentah = $r->get(self::kunciGaleri($r, $hal, $perHal));
            if (!is_string($mentah) || $mentah === '') {
                return null;
            }
            $data = json_decode($mentah, true);
            return is_array($data) ? $data : null;
        } catch (\Throwable) {
            self::lepas();
            return null;
        }
    }

    /**
     * @param list<array<string, mixed>> $data
     */
    public static function simpanGaleri(int $hal, array $data, int $ttl = 60, int $perHal = 12): void
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return;
            }
            $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            if ($json !== false) {
                $r->setex(self::kunciGaleri($r, $hal, $perHal), max(1, $ttl), $json);
            }
        } catch (\Throwable) {
            self::lepas();
        }
    }

    /**
     * @return ?array<string, mixed>
     */
    public static function ambilDetail(int $id): ?array
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return null;
            }
            $mentah = $r->get("puisi:detail:{$id}");
            if (!is_string($mentah) || $mentah === '') {
                return null;
            }
            $data = json_decode($mentah, true);
            return is_array($data) ? $data : null;
        } catch (\Throwable) {
            self::lepas();
            return null;
        }
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function simpanDetail(int $id, array $data, int $ttl = 60): void
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return;
            }
            $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            if ($json !== false) {
                $r->setex("puisi:detail:{$id}", max(1, $ttl), $json);
            }
        } catch (\Throwable) {
            self::lepas();
        }
    }

    public static function invalidasi(?int $idPuisi = null): void
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return;
            }
            $r->incr(self::KUNCI_VERSI_GALERI);
            if ($idPuisi !== null && $idPuisi > 0) {
                $r->del("puisi:detail:{$idPuisi}");
            }
        } catch (\Throwable) {
            self::lepas();
        }
    }

    public static function hIncrBy(string $hash, string $field, int $delta = 1): void
    {
        try {
            $r = self::klien();
            if ($r !== null) {
                $r->hIncrBy($hash, $field, $delta);
            }
        } catch (\Throwable) {
            self::lepas();
        }
    }

    /**
     * Beberapa HINCRBY dan HINCRBYFLOAT dalam satu pipeline, untuk histogram yang dibagi semua replika.
     *
     * @param array<string, int>   $bulat
     * @param array<string, float> $pecahan
     */
    public static function hTambahBanyak(string $hash, array $bulat, array $pecahan = []): void
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return;
            }
            $p = $r->multi(\Redis::PIPELINE);
            foreach ($bulat as $field => $delta) {
                $p->hIncrBy($hash, (string) $field, $delta);
            }
            foreach ($pecahan as $field => $delta) {
                $p->hIncrByFloat($hash, (string) $field, $delta);
            }
            $p->exec();
        } catch (\Throwable) {
            self::lepas();
        }
    }

    /**
     * @return array<string, string>
     */
    public static function hGetAll(string $hash): array
    {
        try {
            $r = self::klien();
            if ($r === null) {
                return [];
            }
            $hasil = $r->hGetAll($hash);
            return is_array($hasil) ? $hasil : [];
        } catch (\Throwable) {
            self::lepas();
            return [];
        }
    }
}

