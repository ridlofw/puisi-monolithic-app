-- ============================================
-- services/puisi/db/init.sql
-- Skema Database poem-db (InnoDB Cluster 3-Node Ready)
-- Tidak ada tabel users dan tidak ada JOIN/FK ke users.
-- ============================================

SET sql_log_bin = 0;

-- Pastikan root dan user aplikasi/replikasi dapat diakses antar-node klaster dan MySQL Router
ALTER USER 'root'@'%' IDENTIFIED BY 'poem';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

CREATE USER IF NOT EXISTS 'poem'@'%' IDENTIFIED BY 'poem';
ALTER USER 'poem'@'%' IDENTIFIED BY 'poem';

CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY 'poem';
ALTER USER 'repl'@'%' IDENTIFIED BY 'poem';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, BACKUP_ADMIN, GROUP_REPLICATION_ADMIN, CONNECTION_ADMIN
    ON *.* TO 'repl'@'%';

CREATE DATABASE IF NOT EXISTS poem_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

GRANT ALL PRIVILEGES ON poem_db.* TO 'poem'@'%';
GRANT SELECT ON performance_schema.* TO 'poem'@'%';
FLUSH PRIVILEGES;

USE poem_db;

CREATE TABLE IF NOT EXISTS puisi (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    user_id         VARCHAR(64)  NOT NULL,
    penulis         VARCHAR(100) NOT NULL,
    judul           VARCHAR(200) NOT NULL,
    isi             TEXT         NOT NULL,
    tgl_submit      DATE         NOT NULL,
    kategori        VARCHAR(100) NULL DEFAULT NULL,
    keyword         VARCHAR(255) NULL DEFAULT NULL,
    file_gambar     VARCHAR(255) NULL DEFAULT NULL,
    status_analisis VARCHAR(20)  NOT NULL DEFAULT 'diproses',
    status_audio    VARCHAR(20)  NOT NULL DEFAULT 'diproses',
    analisis        JSON         NULL DEFAULT NULL,
    url_audio       VARCHAR(255) NULL DEFAULT NULL,
    INDEX idx_puisi_urut (id DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS outbox (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    event_id      CHAR(36)     NOT NULL UNIQUE,
    routing_key   VARCHAR(100) NOT NULL,
    payload       JSON         NOT NULL,
    dibuat_pada   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    terkirim_pada DATETIME(3)  NULL DEFAULT NULL,
    INDEX idx_outbox_belum_terkirim (terkirim_pada, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET sql_log_bin = 1;

