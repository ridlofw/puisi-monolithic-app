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

        // ATTR_TIMEOUT hanya membatasi connect; node yang membeku menerima TCP tetapi tidak pernah
        // mengirim greeting, jadi baca jaringan juga dibatasi agar kegagalannya terdeteksi
        ini_set('mysqlnd.net_read_timeout', Konfig::env('DB_BACA_TIMEOUT', '3'));

        return new PDO($dsn, Konfig::dbUser(), Konfig::dbPass(), [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
            PDO::ATTR_TIMEOUT            => 2,
            // koneksi dipakai ulang oleh proses Apache yang sama (Bab 10.2), tanpa handshake per request
            PDO::ATTR_PERSISTENT         => Konfig::env('DB_PERSISTEN', '1') === '1',
        ]);
    }

    /**
     * Coba host satu per satu, melewati host yang circuit breaker-nya terbuka (Bab 11.2).
     * $uji mengembalikan true bila koneksi layak dipakai; host yang hidup tetapi tidak layak
     * (misalnya secondary saat mencari primary) bukan kegagalan.
     *
     * @param list<string>          $daftar
     * @param callable(PDO): bool   $uji
     * @return array{0: ?PDO, 1: string, 2: ?\Throwable, 3: int}
     */
    private static function cobaHost(array $daftar, callable $uji): array
    {
        $pemutus = Pemutus::bawaan();
        $galat   = null;
        $dicoba  = 0;
        foreach ($daftar as $hostPort) {
            $tujuan = 'db-' . $hostPort;
            if (!$pemutus->bolehCoba($tujuan)) {
                continue;
            }
            $dicoba++;
            try {
                $pdo = self::buatPdo($hostPort);
                $layak = $uji($pdo);
                $pemutus->sukses($tujuan);
                if ($layak) {
                    return [$pdo, $hostPort, null, $dicoba];
                }
            } catch (\Throwable $e) {
                $pemutus->gagal($tujuan);
                $galat = $e;
            }
        }
        return [null, '', $galat, $dicoba];
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

        [$pdo, $hostPort, $galatTerakhir, $dicoba] = self::cobaHost(Konfig::daftarHostTulis(), static function (PDO $pdo): bool {
            $baris = $pdo->query('SELECT @@super_read_only AS ro')->fetch();
            return is_array($baris) && (int) ($baris['ro'] ?? 1) === 0;
        });
        if ($pdo !== null) {
            self::$pdoTulis       = $pdo;
            self::$hostTulisAktif = $hostPort;
            return $pdo;
        }
        if ($dicoba === 0) {
            throw new PDOException('Semua node database tulis sedang diputus circuit breaker, gagal cepat.');
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

        [$pdo, $hostPort, $galatTerakhir, $dicoba] = self::cobaHost(Konfig::daftarHostBaca(), static function (PDO $pdo): bool {
            $pdo->query('SELECT 1');
            return true;
        });
        if ($pdo !== null) {
            self::$pdoBaca       = $pdo;
            self::$hostBacaAktif = $hostPort;
            return $pdo;
        }
        if ($dicoba === 0) {
            throw new PDOException('Semua node database baca sedang diputus circuit breaker, gagal cepat.');
        }

        throw new PDOException(
            'Tidak ada node database baca yang terjangkau: '
            . ($galatTerakhir ? $galatTerakhir->getMessage() : 'daftar host kosong')
        );
    }
}

