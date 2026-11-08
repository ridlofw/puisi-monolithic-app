"""Kerangka consumer RabbitMQ. Tidak perlu diubah saat templat disalin, ganti proses.py.

Konfigurasi lewat environment:
    AMQP_URLS      daftar url node RabbitMQ dipisah koma, dicoba berurutan
    QUEUE          queue yang dikonsumsi, misalnya q.auto-tagging
    NAMA_WORKER    nama untuk log dan metrik
    PORT_METRIK    port /metrics, bawaan 9100
"""
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import amplop
import proses
from metrik import Metrik, layani

EXCHANGE = 'puisi.events'
MAKS_PERCOBAAN = 3
# rabbitmq 4 tidak menghitung nack requeue ke x-delivery-limit, jadi percobaan dihitung di sini
HEADER_PERCOBAAN = 'x-percobaan'


class LogJson(logging.Formatter):
    def format(self, rec):
        isi = {
            'waktu': datetime.now(timezone.utc).isoformat(timespec='milliseconds'),
            'level': rec.levelname,
            'worker': os.environ.get('NAMA_WORKER', 'templat'),
            'pesan': rec.getMessage(),
        }
        isi.update(getattr(rec, 'konteks', {}))
        return json.dumps(isi, ensure_ascii=False)


def siapkan_log():
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(LogJson())
    log = logging.getLogger('worker')
    log.handlers[:] = [h]
    log.setLevel(logging.INFO)
    log.propagate = False
    return log


log = siapkan_log()


def tangani(ch, method, props, body, metrik, terbitkan, ulangi):
    """Proses satu pesan.

    Sukses: ack. Gagal sebelum percobaan ketiga: pesan diterbitkan ulang ke queue yang
    sama dengan penghitung naik, lalu yang lama di-ack. Gagal pada percobaan ketiga:
    reject tanpa requeue, sehingga dead letter exchange memindahkannya ke DLQ.
    """
    mulai = time.monotonic()
    percobaan = int((getattr(props, 'headers', None) or {}).get(HEADER_PERCOBAAN, 1))
    konteks = {'percobaan': percobaan}
    try:
        event = amplop.baca(body)
        konteks.update(correlation_id=event['correlation_id'], event_id=event['event_id'],
                       tipe=event['tipe'])
        for routing_key, data in proses.proses(event) or []:
            terbitkan(routing_key, amplop.buat(routing_key, data, event['correlation_id']))
        ch.basic_ack(delivery_tag=method.delivery_tag)
        metrik.catat(True, time.monotonic() - mulai)
        log.info('pesan selesai', extra={'konteks': konteks})
        return True
    except Exception as e:
        metrik.catat(False, time.monotonic() - mulai)
        konteks['error'] = '%s: %s' % (type(e).__name__, e)
        if percobaan >= MAKS_PERCOBAAN:
            ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            log.error('pesan gagal %d kali, dipindah ke DLQ' % percobaan, extra={'konteks': konteks})
            return False
        try:
            ulangi(body, props, percobaan + 1)
            ch.basic_ack(delivery_tag=method.delivery_tag)
            log.warning('pesan gagal, diulang', extra={'konteks': konteks})
        except Exception as e2:
            # tidak bisa menerbitkan ulang, biarkan broker yang mengembalikan pesannya
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            konteks['error_ulang'] = repr(e2)
            log.warning('pesan gagal dan gagal diulang, dikembalikan ke queue', extra={'konteks': konteks})
        return False


def sambung(pika, urls):
    """Coba setiap node berurutan. Node yang mati bisa hilang dari DNS Docker, jadi OSError ikut ditangkap."""
    for url in urls:
        p = pika.URLParameters(url)
        p.heartbeat = 30
        p.connection_attempts = 1
        p.socket_timeout = 5
        try:
            return pika.BlockingConnection(p), p.host
        except (pika.exceptions.AMQPConnectionError, OSError) as e:
            log.warning('node tidak terjangkau', extra={'konteks': {'node': p.host, 'error': repr(e)}})
    return None, None


def jalankan():
    import pika

    urls = [u.strip() for u in os.environ['AMQP_URLS'].split(',') if u.strip()]
    queue = os.environ['QUEUE']
    nama = os.environ.get('NAMA_WORKER', 'templat')
    metrik = Metrik(nama, queue)
    layani(metrik, int(os.environ.get('PORT_METRIK', '9100')))

    while True:
        try:
            koneksi, node = sambung(pika, urls)
            if koneksi is None:
                log.warning('tidak ada node RabbitMQ yang terjangkau, mencoba lagi dalam 3 detik')
                time.sleep(3)
                continue
            ch = koneksi.channel()
            ch.confirm_delivery()
            ch.basic_qos(prefetch_count=1)

            def terbitkan(routing_key, event):
                ch.basic_publish(
                    exchange=EXCHANGE, routing_key=routing_key, body=amplop.ke_bytes(event),
                    properties=pika.BasicProperties(
                        content_type='application/json', delivery_mode=2,
                        message_id=event['event_id'], correlation_id=event['correlation_id'],
                        type=routing_key))

            def ulangi(body, props, percobaan):
                # jeda pendek agar gangguan sesaat, misalnya basis data restart, sempat pulih
                time.sleep(min(2 ** (percobaan - 2), 4))
                headers = dict(props.headers or {})
                headers[HEADER_PERCOBAAN] = percobaan
                ch.basic_publish(
                    exchange='', routing_key=queue, body=body,
                    properties=pika.BasicProperties(
                        content_type=props.content_type, delivery_mode=2,
                        message_id=props.message_id, correlation_id=props.correlation_id,
                        type=props.type, headers=headers))

            def callback(ch_, method, props, body):
                tangani(ch_, method, props, body, metrik, terbitkan, ulangi)

            ch.basic_consume(queue=queue, on_message_callback=callback)
            log.info('terhubung, mengonsumsi %s' % queue, extra={'konteks': {'node': node}})
            ch.start_consuming()
        except (pika.exceptions.AMQPConnectionError, pika.exceptions.AMQPChannelError, OSError) as e:
            log.warning('koneksi ke RabbitMQ putus, mencoba lagi dalam 3 detik',
                        extra={'konteks': {'error': repr(e)}})
            time.sleep(3)


if __name__ == '__main__':
    jalankan()
