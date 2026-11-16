<?php
declare(strict_types=1);

namespace Pencarian;

//Log JSON satu baris ke stdout, bentuknya sama dengan layanan lain.
final class Log
{
    public static function catat(string $level, string $pesan, array $konteks = []): void
    {
        $baris = array_merge([
            'waktu'  => (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))->format('Y-m-d\TH:i:s.vP'),
            'level'  => $level,
            'worker' => Konfig::env('NAMA_LAYANAN', 'search-consumer'),
            'pesan'  => $pesan,
        ], $konteks);
        $json = json_encode($baris, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($json !== false) {
            fwrite(STDOUT, $json . "\n");
        }
    }

    public static function info(string $pesan, array $k = []): void
    {
        self::catat('INFO', $pesan, $k);
    }

    public static function peringatan(string $pesan, array $k = []): void
    {
        self::catat('WARNING', $pesan, $k);
    }
    
    public static function error(string $pesan, array $k = []): void
    {
        self::catat('ERROR', $pesan, $k);
    }
}
