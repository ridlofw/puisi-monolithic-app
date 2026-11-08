<?php
declare(strict_types=1);

namespace Puisi;

final class Log
{
    /** @param array<string, mixed> $konteks */
    public static function catat(string $level, string $pesan, array $konteks = []): void
    {
        $waktu = (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))->format('Y-m-d\TH:i:s.vP');
        $baris = array_merge([
            'waktu'  => $waktu,
            'level'  => strtoupper($level),
            'worker' => Konfig::env('NAMA_LAYANAN', 'poem-service'),
            'pesan'  => $pesan,
        ], $konteks);

        $json = json_encode($baris, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($json === false) {
            return;
        }
        $stream = defined('STDOUT') ? STDOUT : fopen('php://stdout', 'wb');
        if (is_resource($stream)) {
            fwrite($stream, $json . "\n");
        }
    }

    /** @param array<string, mixed> $konteks */
    public static function info(string $pesan, array $konteks = []): void
    {
        self::catat('INFO', $pesan, $konteks);
    }

    /** @param array<string, mixed> $konteks */
    public static function peringatan(string $pesan, array $konteks = []): void
    {
        self::catat('WARNING', $pesan, $konteks);
    }

    /** @param array<string, mixed> $konteks */
    public static function error(string $pesan, array $konteks = []): void
    {
        self::catat('ERROR', $pesan, $konteks);
    }
}

