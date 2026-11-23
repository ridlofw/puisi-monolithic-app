<?php
declare(strict_types=1);

namespace Puisi;

use PDO;

/**
 * Tabel yang ditambahkan setelah klaster berjalan. Dibuat lewat koneksi primary agar
 * tercatat di binlog dan tereplikasi ke semua node. init.sql mematikan sql_log_bin, jadi
 * tabel baru tidak boleh ditambahkan di sana.
 */
final class Skema
{
    public const IDEMPOTENSI = 'CREATE TABLE IF NOT EXISTS idempotensi (
        user_id     VARCHAR(64) NOT NULL,
        kunci       VARCHAR(64) NOT NULL,
        sidik       CHAR(64)    NOT NULL,
        puisi_id    INT         NOT NULL,
        dibuat_pada DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (user_id, kunci),
        INDEX idx_idempotensi_waktu (dibuat_pada)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci';

    public static function pastikan(PDO $pdo): void
    {
        $pdo->exec(self::IDEMPOTENSI);
    }

    public static function tabelHilang(\Throwable $e): bool
    {
        return $e instanceof \PDOException && $e->getCode() === '42S02';
    }
}
