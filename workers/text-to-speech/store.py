"""MySQL job state and transactional outbox."""
import json
import os
import time
import uuid
from contextlib import closing

import pymysql
from pymysql.cursors import DictCursor


class JobStore:
    def __init__(self):
        self.config = {
            "host": os.environ.get("DB_HOST", "tts-db"),
            "port": int(os.environ.get("DB_PORT", "3306")),
            "user": os.environ.get("DB_USER", "tts"),
            "password": self._secret("DB_PASSWORD_FILE", "/run/secrets/tts_db_password"),
            "database": os.environ.get("DB_NAME", "tts"),
            "charset": "utf8mb4",
            "cursorclass": DictCursor,
            "autocommit": False,
            "connect_timeout": 5,
            "read_timeout": 10,
            "write_timeout": 10,
        }

    @staticmethod
    def _secret(variable, default):
        path = os.environ.get(variable, default)
        with open(path, encoding="utf-8") as secret:
            return secret.read().strip()

    def connect(self):
        return pymysql.connect(**self.config)

    def claim(self, puisi_id):
        """Claim with a lease; a concurrently active duplicate is safe to ack."""
        with closing(self.connect()) as db:
            with db.cursor() as cur:
                cur.execute(
                    "INSERT IGNORE INTO job (puisi_id,status) VALUES (%s,'antre')", (puisi_id,)
                )
                cur.execute("SELECT * FROM job WHERE puisi_id=%s FOR UPDATE", (puisi_id,))
                job = cur.fetchone()
                if job["status"] in ("selesai", "gagal"):
                    db.commit()
                    return {"state": job["status"], "attempt": job["attempt_count"]}
                cur.execute(
                    "SELECT lease_until > UTC_TIMESTAMP(6) AS active FROM job WHERE puisi_id=%s",
                    (puisi_id,),
                )
                if job["status"] == "proses" and cur.fetchone()["active"]:
                    db.commit()
                    return {"state": "busy", "attempt": job["attempt_count"]}
                if job["attempt_count"] >= 3:
                    cur.execute(
                        "UPDATE job SET status='gagal',lease_until=NULL,lease_token=NULL WHERE puisi_id=%s",
                        (puisi_id,),
                    )
                    db.commit()
                    return {"state": "gagal", "attempt": 3}
                attempt = job["attempt_count"] + 1
                token = str(uuid.uuid4())
                cur.execute(
                    "UPDATE job SET status='proses',attempt_count=%s,lease_until=DATE_ADD(UTC_TIMESTAMP(6),INTERVAL 15 MINUTE),lease_token=%s,last_error=NULL WHERE puisi_id=%s",
                    (attempt, token, puisi_id),
                )
            db.commit()
            return {"state": "claimed", "attempt": attempt, "token": token}

    def complete(self, puisi_id, token, audio_key, duration, event):
        """Mark success and persist the completion event in one DB transaction."""
        body = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        with closing(self.connect()) as db:
            with db.cursor() as cur:
                cur.execute(
                    "UPDATE job SET status='selesai',audio_key=%s,durasi_detik=%s,lease_until=NULL,lease_token=NULL,last_error=NULL WHERE puisi_id=%s AND status='proses' AND lease_token=%s",
                    (audio_key, duration, puisi_id, token),
                )
                if cur.rowcount != 1:
                    raise RuntimeError("Job lease no longer belongs to this worker.")
                cur.execute(
                    "INSERT IGNORE INTO event_outbox (event_id,routing_key,body) VALUES (%s,'audio.siap',%s)",
                    (event["event_id"], body),
                )
            db.commit()

    def fail(self, puisi_id, token, attempt, error, final):
        status = "gagal" if final else "antre"
        with closing(self.connect()) as db:
            with db.cursor() as cur:
                cur.execute(
                    "UPDATE job SET status=%s,attempt_count=GREATEST(attempt_count,%s),lease_until=NULL,lease_token=NULL,last_error=%s WHERE puisi_id=%s AND status='proses' AND lease_token=%s",
                    (status, attempt, str(error)[:1000], puisi_id, token),
                )
            db.commit()

    def pending_events(self, limit=20):
        with closing(self.connect()) as db, db.cursor() as cur:
            cur.execute(
                "SELECT id,event_id,routing_key,body FROM event_outbox WHERE published_at IS NULL ORDER BY id LIMIT %s",
                (limit,),
            )
            return cur.fetchall()

    def mark_published(self, row_id):
        with closing(self.connect()) as db, db.cursor() as cur:
            cur.execute("UPDATE event_outbox SET published_at=UTC_TIMESTAMP(6) WHERE id=%s AND published_at IS NULL", (row_id,))
            db.commit()


def wait_for_database(store, logger):
    while True:
        try:
            with closing(store.connect()) as db:
                db.ping(reconnect=False)
            return
        except Exception as error:
            logger.warning("database not ready: %s", error)
            time.sleep(3)
