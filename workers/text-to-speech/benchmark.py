"""Publish unique synthetic poem jobs and measure queue drain time in-container."""
import argparse
import json
import os
import time
import uuid
from datetime import datetime, timezone

import pika

from store import JobStore


POEM = """Pagi menyapa pucuk cemara
Embun berkilau di ujung daun
Kita menjaga bumi bersama
Menanam harap untuk masa depan"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--start-id", type=int, required=True)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    urls = [u.strip() for u in os.environ["AMQP_URLS"].split(",") if u.strip()]
    store = JobStore()

    connection = None
    for url in urls:
        try:
            connection = pika.BlockingConnection(pika.URLParameters(url))
            break
        except (pika.exceptions.AMQPConnectionError, OSError):
            continue
    if connection is None:
        raise SystemExit("No RabbitMQ node is reachable")

    start = time.monotonic()
    try:
        channel = connection.channel()
        channel.confirm_delivery()
        for puisi_id in range(args.start_id, args.start_id + args.count):
            event_id = str(uuid.uuid4())
            event = {
                "event_id": event_id,
                "tipe": "puisi.dibuat",
                "versi": 1,
                "terjadi_pada": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "correlation_id": f"benchmark-{args.start_id}",
                "data": {"puisi_id": puisi_id, "judul": "Uji Beban", "isi": POEM,
                         "penulis": "benchmark", "kategori": None, "keyword": None},
            }
            channel.basic_publish(
                exchange="puisi.events", routing_key="puisi.dibuat",
                body=json.dumps(event, ensure_ascii=False).encode("utf-8"), mandatory=True,
                properties=pika.BasicProperties(content_type="application/json", delivery_mode=2,
                    message_id=event_id, correlation_id=event["correlation_id"], type="puisi.dibuat"),
            )
    finally:
        connection.close()

    deadline = time.monotonic() + args.timeout
    expected = set(range(args.start_id, args.start_id + args.count))
    while time.monotonic() < deadline:
        with store.connect() as db:
            with db.cursor() as cursor:
                placeholders = ",".join(["%s"] * len(expected))
                cursor.execute(
                    f"SELECT puisi_id,status FROM job WHERE puisi_id IN ({placeholders})",
                    tuple(expected),
                )
                rows = cursor.fetchall()
        if len(rows) == args.count and all(row["status"] in ("selesai", "gagal") for row in rows):
            break
        time.sleep(0.5)
    elapsed = time.monotonic() - start
    completed = sum(row["status"] == "selesai" for row in rows)
    failed = sum(row["status"] == "gagal" for row in rows)
    print(json.dumps({
        "published": args.count, "completed": completed, "failed": failed,
        "elapsed_seconds": round(elapsed, 3),
        "throughput_jobs_per_second": round(args.count / elapsed, 3) if elapsed else 0,
        "timed_out": len(rows) != args.count or completed + failed != args.count,
    }))
    if len(rows) != args.count or completed + failed != args.count or failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
