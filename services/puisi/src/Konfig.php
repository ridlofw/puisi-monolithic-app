<?php
declare(strict_types=1);

namespace Puisi;

final class Konfig
{
    public static function env(string $kunci, string $bawaan = ''): string
    {
        $nilai = getenv($kunci);
        if ($nilai === false || $nilai === '') {
            $nilai = $_ENV[$kunci] ?? $_SERVER[$kunci] ?? '';
        }
        $teks = trim((string) $nilai);
        return $teks !== '' ? $teks : $bawaan;
    }

    /** @return list<string> */
    public static function daftar(string $kunci, string $bawaan): array
    {
        $mentah = self::env($kunci, $bawaan);
        $bagian = array_map('trim', explode(',', $mentah));
        return array_values(array_filter($bagian, static fn(string $s): bool => $s !== ''));
    }

    /** @return list<string> */
    public static function daftarHostTulis(): array
    {
        $khusus = self::env('DB_WRITE_HOSTS', '');
        if ($khusus !== '') {
            return self::daftar('DB_WRITE_HOSTS', $khusus);
        }
        $hostTunggal = self::env('DB_HOST', '');
        if ($hostTunggal !== '') {
            return [str_contains($hostTunggal, ':') ? $hostTunggal : $hostTunggal . ':3306'];
        }
        return [
            'poem-db-router-1:6446',
            'poem-db-router-2:6446',
            'poem-db-1:3306',
            'poem-db-2:3306',
            'poem-db-3:3306',
        ];
    }

    /** @return list<string> */
    public static function daftarHostBaca(): array
    {
        $khusus = self::env('DB_READ_HOSTS', '');
        if ($khusus !== '') {
            return array_values(array_unique(array_merge(
                self::daftar('DB_READ_HOSTS', $khusus),
                self::daftarHostTulis()
            )));
        }
        $hostBaca = self::env('DB_READ_HOST', '');
        if ($hostBaca !== '') {
            $utama = str_contains($hostBaca, ':') ? $hostBaca : $hostBaca . ':3306';
            return array_values(array_unique(array_merge([$utama], self::daftarHostTulis())));
        }
        return array_values(array_unique(array_merge([
            'poem-db-router-1:6447',
            'poem-db-router-2:6447',
        ], self::daftarHostTulis())));
    }

    public static function dbNama(): string
    {
        return self::env('DB_NAME', 'poem_db');
    }

    public static function dbUser(): string
    {
        return self::env('DB_USER', 'poem');
    }

    public static function dbPass(): string
    {
        return self::env('DB_PASS', 'poem');
    }

    /** @return list<string> */
    public static function daftarHostRedis(): array
    {
        $khusus = self::env('REDIS_HOSTS', '');
        if ($khusus !== '') {
            return self::daftar('REDIS_HOSTS', $khusus);
        }
        $tunggal = self::env('REDIS_HOST', 'redis:6379');
        return [str_contains($tunggal, ':') ? $tunggal : $tunggal . ':6379'];
    }

    /** @return list<string> */
    public static function daftarUrlAmqp(): array
    {
        return self::daftar(
            'AMQP_URLS',
            'amqp://puisi:puisi@rabbitmq-1:5672/%2F,amqp://puisi:puisi@rabbitmq-2:5672/%2F,amqp://puisi:puisi@rabbitmq-3:5672/%2F'
        );
    }

    /** @return list<string> */
    public static function sumberWajib(): array
    {
        return self::daftar('SUMBER_WAJIB', 'auto-tagging,klasifikasi-genre');
    }

    public static function kunciJwt(): string
    {
        $langsung = self::env('JWT_SECRET', '');
        if ($langsung !== '') {
            return $langsung;
        }
        $jalur = [
            self::env('JWT_SECRET_FILE', ''),
            '/run/secrets/jwt_secret',
            dirname(__DIR__, 3) . '/secrets/jwt_secret.txt',
        ];
        foreach ($jalur as $file) {
            if ($file !== '' && is_readable($file)) {
                $isi = trim((string) file_get_contents($file));
                if ($isi !== '') {
                    return $isi;
                }
            }
        }
        throw new \RuntimeException('Kunci JWT tidak ditemukan di /run/secrets/jwt_secret.');
    }
}

