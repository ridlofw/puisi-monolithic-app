"""RabbitMQ consumer with DB-backed retries and an audio.siap outbox relay."""
import json
import logging
import os
import signal
import threading
import time
from datetime import datetime, timezone

import boto3
import pika
from botocore.config import Config

import amplop
from metrik import Metrik, layani
from store import JobStore, wait_for_database
from suara import synthesize_poem

QUEUE = "q.text-to-speech"
EXCHANGE = "puisi.events"
MAX_ATTEMPTS = 3
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(message)s")
log = logging.getLogger("tts-worker")
stop_event = threading.Event()


def json_log(level, message, **context):
    getattr(log, level)(json.dumps({
        "waktu": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "level": level.upper(), "worker": "text-to-speech", "pesan": message, **context,
    }, ensure_ascii=False))


def make_s3():
    def read_secret(env_name, default_path):
        with open(os.environ.get(env_name, default_path), encoding="utf-8") as stream:
            return stream.read().strip()

    is_init = os.environ.get("TTS_INIT_STORAGE") == "1"
    access_key_file = "/run/secrets/s3_init_access_key" if is_init else "/run/secrets/s3_access_key"
    secret_key_file = "/run/secrets/s3_init_secret_key" if is_init else "/run/secrets/s3_secret_key"
    return boto3.client(
        "s3", endpoint_url=os.environ.get("S3_ENDPOINT", "http://seaweedfs:8333"),
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
        aws_access_key_id=read_secret("AWS_ACCESS_KEY_FILE", access_key_file),
        aws_secret_access_key=read_secret("AWS_SECRET_KEY_FILE", secret_key_file),
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 2}),
    )


def connect_amqp(urls):
    for url in urls:
        params = pika.URLParameters(url)
        params.heartbeat = 30
        params.connection_attempts = 1
        params.socket_timeout = 5
        try:
            return pika.BlockingConnection(params), params.host
        except (pika.exceptions.AMQPConnectionError, OSError) as error:
            json_log("warning", "RabbitMQ node unavailable", node=params.host, error=str(error))
    return None, None


def publish_outbox(store, urls, once=False):
    """Only mark records after the broker confirms a persistent publish."""
    while not stop_event.is_set():
        try:
            rows = store.pending_events()
            if rows:
                connection, node = connect_amqp(urls)
                if connection is None:
                    raise ConnectionError("No RabbitMQ node is available")
                try:
                    channel = connection.channel()
                    channel.confirm_delivery()
                    for row in rows:
                        event = row["body"]
                        if isinstance(event, str):
                            event = event.encode("utf-8")
                        envelope = json.loads(event)
                        published = channel.basic_publish(
                            exchange=EXCHANGE, routing_key=row["routing_key"], body=event,
                            properties=pika.BasicProperties(
                                content_type="application/json", delivery_mode=2,
                                message_id=row["event_id"], type=row["routing_key"],
                                correlation_id=envelope.get("correlation_id"),
                            ), mandatory=True,
                        )
                        if published is False:
                            raise ConnectionError("RabbitMQ did not confirm outbox publish")
                        store.mark_published(row["id"])
                        json_log("info", "outbox event published", event_id=row["event_id"], node=node)
                finally:
                    connection.close()
        except Exception as error:
            json_log("warning", "outbox relay will retry", error=str(error))
        if once:
            return
        stop_event.wait(2)


def validate_event(body):
    event = amplop.baca(body)
    if event["tipe"] != "puisi.dibuat":
        raise ValueError("event type must be puisi.dibuat")
    data = event["data"]
    puisi_id = data.get("puisi_id")
    if isinstance(puisi_id, bool) or not isinstance(puisi_id, int) or puisi_id < 1:
        raise ValueError("puisi_id must be a positive integer")
    isi = data.get("isi")
    if not isinstance(isi, str) or not isi.strip():
        raise ValueError("isi must be a non-empty string")
    return event, puisi_id, isi


def process_message(channel, method, properties, body, store, s3, metrics):
    started = time.monotonic()
    event = None
    puisi_id = None
    lease_token = None
    try:
        attempt = int((getattr(properties, "headers", None) or {}).get("x-percobaan", 1))
    except (TypeError, ValueError):
        attempt = MAX_ATTEMPTS
    if attempt < 1 or attempt > MAX_ATTEMPTS:
        attempt = MAX_ATTEMPTS
    try:
        event, puisi_id, poem = validate_event(body)
        job = store.claim(puisi_id)
        if job["state"] == "selesai":
            channel.basic_ack(delivery_tag=method.delivery_tag)
            metrics.catat(True, time.monotonic() - started)
            json_log("info", "duplicate event safely acknowledged", puisi_id=puisi_id, state=job["state"])
            return
        if job["state"] == "gagal":
            channel.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            metrics.catat(False, time.monotonic() - started)
            json_log("error", "job exhausted persisted attempts and routed to DLQ", puisi_id=puisi_id)
            return
        if job["state"] == "busy":
            time.sleep(2)
            published = channel.basic_publish(
                exchange="", routing_key=QUEUE, body=body,
                properties=pika.BasicProperties(content_type="application/json", delivery_mode=2,
                    message_id=getattr(properties, "message_id", None),
                    correlation_id=getattr(properties, "correlation_id", None),
                    type="puisi.dibuat", headers=dict(getattr(properties, "headers", None) or {})),
                mandatory=True,
            )
            if published is False:
                raise ConnectionError("busy duplicate publish was not confirmed")
            channel.basic_ack(delivery_tag=method.delivery_tag)
            return
        attempt = job["attempt"]
        lease_token = job["token"]
        key = f"puisi_{puisi_id}.mp3"
        output = f"/tmp/{key}"
        result = synthesize_poem(poem, output)
        with open(output, "rb") as audio:
            s3.put_object(Bucket=os.environ.get("S3_BUCKET", "audio"), Key=key,
                          Body=audio, ContentType="audio/mpeg")

        completion = amplop.buat("audio.siap", {
            "puisi_id": puisi_id,
            "url_audio": f"/audio/{key}",
            "durasi_detik": round(result.duration_seconds, 3),
            "mesin": "piper-id_ID-news_tts-medium",
        }, event["correlation_id"])
        store.complete(puisi_id, lease_token, key, result.duration_seconds, completion)
        channel.basic_ack(delivery_tag=method.delivery_tag)
        metrics.catat(True, time.monotonic() - started)
        json_log("info", "poem audio stored", puisi_id=puisi_id, event_id=event["event_id"],
                 correlation_id=event["correlation_id"], audio_key=key,
                 duration_seconds=result.duration_seconds, processing_seconds=result.processing_seconds)
    except Exception as error:
        metrics.catat(False, time.monotonic() - started)
        is_permanent = isinstance(error, (ValueError, amplop.AmplopTidakSah))
        final = attempt >= MAX_ATTEMPTS
        if is_permanent:
            final = True
        if puisi_id is not None:
            try:
                store.fail(puisi_id, lease_token, attempt, error, final)
            except Exception as db_error:
                json_log("error", "could not persist failed job state", puisi_id=puisi_id,
                         error=str(db_error))
        if final:
            channel.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            json_log("error", "message exhausted attempts and routed to DLQ", puisi_id=puisi_id,
                     attempt=attempt, error=str(error))
            return
        try:
            delay = min(2 ** (attempt - 1), 4)
            time.sleep(delay)
            headers = dict(getattr(properties, "headers", None) or {})
            headers["x-percobaan"] = attempt + 1
            accepted = channel.basic_publish(
                exchange="", routing_key=QUEUE, body=body,
                properties=pika.BasicProperties(
                    content_type=getattr(properties, "content_type", "application/json"),
                    delivery_mode=2, message_id=getattr(properties, "message_id", None),
                    correlation_id=getattr(properties, "correlation_id", None),
                    type=getattr(properties, "type", "puisi.dibuat"), headers=headers,
                ), mandatory=True,
            )
            if accepted is False:
                raise ConnectionError("retry publish was not confirmed")
            channel.basic_ack(delivery_tag=method.delivery_tag)
            json_log("warning", "message republished for retry", puisi_id=puisi_id,
                     attempt=attempt + 1, error=str(error))
        except Exception as retry_error:
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            json_log("error", "retry publish failed; original returned to queue", puisi_id=puisi_id,
                     error=str(retry_error))


def main():
    urls = [url.strip() for url in os.environ["AMQP_URLS"].split(",") if url.strip()]
    store = JobStore()
    wait_for_database(store, log)
    s3 = make_s3()
    s3.head_bucket(Bucket=os.environ.get("S3_BUCKET", "audio"))
    metrics = Metrik("text-to-speech", QUEUE)
    layani(metrics, int(os.environ.get("PORT_METRIK", "9100")))
    relay = threading.Thread(target=publish_outbox, args=(store, urls), daemon=True)
    relay.start()

    def stop(*_):
        stop_event.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while not stop_event.is_set():
        connection, node = connect_amqp(urls)
        if connection is None:
            stop_event.wait(3)
            continue
        try:
            channel = connection.channel()
            channel.confirm_delivery()
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(
                queue=QUEUE,
                on_message_callback=lambda ch, method, props, body: process_message(
                    ch, method, props, body, store, s3, metrics),
            )
            json_log("info", "consumer ready", queue=QUEUE, node=node, prefetch=1)
            while connection.is_open and not stop_event.is_set():
                connection.process_data_events(time_limit=1)
        except (pika.exceptions.AMQPConnectionError, pika.exceptions.AMQPChannelError, OSError) as error:
            json_log("warning", "consumer connection interrupted", error=str(error))
            stop_event.wait(3)
        finally:
            if connection.is_open:
                connection.close()
    stop_event.set()
    relay.join(timeout=5)


if __name__ == "__main__":
    main()
