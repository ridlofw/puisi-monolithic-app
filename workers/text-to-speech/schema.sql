CREATE TABLE IF NOT EXISTS job (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  puisi_id BIGINT UNSIGNED NOT NULL,
  status ENUM('antre','proses','selesai','gagal') NOT NULL DEFAULT 'antre',
  audio_key VARCHAR(512) NULL,
  durasi_detik DECIMAL(10,3) NULL,
  attempt_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
  lease_until DATETIME(6) NULL,
  lease_token CHAR(36) NULL,
  last_error VARCHAR(1000) NULL,
  dibuat_pada DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  diperbarui_pada DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uq_job_puisi_id (puisi_id),
  KEY ix_job_status_updated (status, diperbarui_pada),
  CONSTRAINT chk_job_attempt_count CHECK (attempt_count <= 3),
  CONSTRAINT chk_job_audio_state CHECK (
    (status <> 'selesai') OR (audio_key IS NOT NULL AND durasi_detik IS NOT NULL)
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS event_outbox (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event_id CHAR(36) NOT NULL,
  routing_key VARCHAR(100) NOT NULL,
  body JSON NOT NULL,
  published_at DATETIME(6) NULL,
  dibuat_pada DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uq_outbox_event_id (event_id),
  KEY ix_outbox_pending (published_at, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
