-- ============================================
-- query.sql
-- Skema Database untuk Aplikasi Puisi
-- ============================================

CREATE DATABASE IF NOT EXISTS puisi_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE puisi_db;

-- Tabel users
CREATE TABLE IF NOT EXISTS users (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    username   VARCHAR(50)  NOT NULL UNIQUE,
    password   VARCHAR(255) NOT NULL,
    nama       VARCHAR(100) NOT NULL,
    no_id      VARCHAR(50)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Tabel puisi dengan Foreign Key ke users
CREATE TABLE IF NOT EXISTS puisi (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT          NOT NULL,
    judul      VARCHAR(200) NOT NULL,
    tgl_submit DATE         NOT NULL,
    isi        TEXT         NOT NULL,
    kategori   VARCHAR(100) NOT NULL,
    keyword    VARCHAR(255) NOT NULL,
    file_gambar VARCHAR(255) NOT NULL,  -- ditambah kolom file_gambar (menyimpan referensi saja)
    CONSTRAINT fk_puisi_user
        FOREIGN KEY (user_id) REFERENCES users(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
