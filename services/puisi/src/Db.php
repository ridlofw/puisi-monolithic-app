<?php
declare(strict_types=1);

namespace Puisi;

use PDO;
use PDOException;

final class Db
{
    private static ?PDO $pdoTulis = null;
    private static ?PDO $pdoBaca  = null;
    private static string $hostTulisAktif = '';
    private static string $hostBacaAktif  = '';

    public static function putus(): void
    {
        self::$pdoTulis       = null;
        self::$pdoBaca        = null;
        self::$hostTulisAktif = '';
        self::$hostBacaAktif  = '';
    }

    public static function hostTulisAktif(): string
    {
        return self::$hostTulisAktif;
    }

    public static function hostBacaAktif(): string
    {
        return self::$hostBacaAktif;
    }

    private static function buatPdo(string $hostPort): PDO
    {
        $bagian = explode(':', $hostPort, 2);
        $host   = $bagian[0];
        $port   = isset($bagian[1]) && $bagian[1] !== '' ? (int) $bagian[1] : 3306;
        $db     = Konfig::dbNama();
        $dsn    = "mysql:host={$host};port={$port};dbname={$db};charset=utf8mb4";

        return new PDO($dsn, Konfig::dbUser(), Konfig::dbPass(), [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
            PDO::ATTR_TIMEOUT            => 2,
        ]);
    }

    /**
     * Koneksi tulis ke MySQL Router RW (6446) atau node Primary InnoDB Cluster.
     * Memastikan @@super_read_only = 0 sehingga aman saat failover langsung ke node DB.
     */
    public static function tulis(): PDO
    {
        if (self::$pdoTulis !== null) {
            try {
                $baris = self::$pdoTulis->query('SELECT @@super_read_only AS ro')->fetch();
                if (is_array($baris) && (int) ($baris['ro'] ?? 1) === 0) {
                    return self::$pdoTulis;
                }
            } catch (\Throwable) {
            }
            self::$pdoTulis = null;
        }

        $galatTerakhir = null;
        foreach (Konfig::daftarHostTulis() as $hostPort) {
            try {
                $pdo   = self::buatPdo($hostPort);
                $baris = $pdo->query('SELECT @@super_read_only AS ro')->fetch();
                if (is_array($baris) && (int) ($baris['ro'] ?? 1) === 0) {
                    self::$pdoTulis       = $pdo;
                    self::$hostTulisAktif = $hostPort;
                    return $pdo;
                }
            } catch (\Throwable $e) {
                $galatTerakhir = $e;
            }
        }

        throw new PDOException(
            'Tidak ada node database tulis (Primary) yang terjangkau: '
            . ($galatTerakhir ? $galatTerakhir->getMessage() : 'daftar host kosong')
        );
    }

    /**
     * Koneksi baca ke MySQL Router RO (6447) / Secondary, otomatis kembali ke Primary bila gagal.
     */
    public static function baca(): PDO
    {
        if (self::$pdoBaca !== null) {
            try {
                self::$pdoBaca->query('SELECT 1');
                return self::$pdoBaca;
            } catch (\Throwable) {
                self::$pdoBaca = null;
            }
        }

        $galatTerakhir = null;
        foreach (Konfig::daftarHostBaca() as $hostPort) {
            try {
                $pdo = self::buatPdo($hostPort);
                $pdo->query('SELECT 1');
                self::$pdoBaca       = $pdo;
                self::$hostBacaAktif = $hostPort;
                return $pdo;
            } catch (\Throwable $e) {
                $galatTerakhir = $e;
            }
        }

        throw new PDOException(
            'Tidak ada node database baca yang terjangkau: '
            . ($galatTerakhir ? $galatTerakhir->getMessage() : 'daftar host kosong')
        );
    }
}

