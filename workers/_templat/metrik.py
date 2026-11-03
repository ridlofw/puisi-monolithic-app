"""Metrik Prometheus dalam format teks, tanpa pustaka tambahan."""
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BATAS = (0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30)


class Metrik(object):
    def __init__(self, worker, queue):
        self.label = 'worker="%s",queue="%s"' % (worker, queue)
        self.diproses = 0
        self.gagal = 0
        self.ember = [0] * len(BATAS)
        self.jumlah_durasi = 0.0
        self.hitung_durasi = 0
        self._kunci = threading.Lock()

    def catat(self, sukses, durasi):
        with self._kunci:
            if sukses:
                self.diproses += 1
            else:
                self.gagal += 1
            for i, b in enumerate(BATAS):
                if durasi <= b:
                    self.ember[i] += 1
            self.jumlah_durasi += durasi
            self.hitung_durasi += 1

    def teks(self):
        with self._kunci:
            l = self.label
            baris = [
                '# HELP worker_pesan_diproses_total Pesan yang selesai diproses dan di-ack.',
                '# TYPE worker_pesan_diproses_total counter',
                'worker_pesan_diproses_total{%s} %d' % (l, self.diproses),
                '# HELP worker_pesan_gagal_total Percobaan yang gagal dan dikembalikan ke queue.',
                '# TYPE worker_pesan_gagal_total counter',
                'worker_pesan_gagal_total{%s} %d' % (l, self.gagal),
                '# HELP worker_durasi_detik Lama pemrosesan satu pesan.',
                '# TYPE worker_durasi_detik histogram',
            ]
            for b, n in zip(BATAS, self.ember):
                baris.append('worker_durasi_detik_bucket{%s,le="%s"} %d' % (l, b, n))
            baris.append('worker_durasi_detik_bucket{%s,le="+Inf"} %d' % (l, self.hitung_durasi))
            baris.append('worker_durasi_detik_sum{%s} %.6f' % (l, self.jumlah_durasi))
            baris.append('worker_durasi_detik_count{%s} %d' % (l, self.hitung_durasi))
            return '\n'.join(baris) + '\n'


def layani(metrik, port):
    class Penangan(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/metrics':
                self.send_response(404)
                self.end_headers()
                return
            isi = metrik.teks().encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(isi)))
            self.end_headers()
            self.wfile.write(isi)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('0.0.0.0', port), Penangan)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
