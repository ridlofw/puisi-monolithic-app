"""Pembungkus kecil HTTP API management RabbitMQ, dipakai script lain di folder ini."""
import base64
import json
import os
import urllib.error
import urllib.request

# satu api per node, dicoba berurutan sehingga script tetap jalan saat satu node mati
API = [u.strip() for u in os.environ.get(
    'RABBITMQ_API', 'http://localhost:15672/api,http://localhost:15673/api,http://localhost:15674/api'
).split(',') if u.strip()]
PENGGUNA = os.environ.get('RABBITMQ_USER', 'puisi')
SANDI = os.environ.get('RABBITMQ_PASS', 'puisi')
VHOST = '%2F'


def panggil(metode, path, isi=None):
    data = json.dumps(isi).encode('utf-8') if isi is not None else None
    kunci = base64.b64encode(('%s:%s' % (PENGGUNA, SANDI)).encode()).decode()
    alasan = []
    for basis in API:
        req = urllib.request.Request(basis + path, data=data, method=metode)
        req.add_header('Authorization', 'Basic ' + kunci)
        req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=10) as res:
                badan = res.read()
                return json.loads(badan) if badan else None
        except urllib.error.HTTPError as e:
            raise SystemExit('RabbitMQ API %s %s: HTTP %d %s' % (metode, path, e.code, e.read().decode()[:200]))
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            alasan.append('%s (%s)' % (basis, getattr(e, 'reason', e)))
    raise SystemExit('RabbitMQ API tidak terjangkau: %s. Sudah docker compose up?' % '; '.join(alasan))
