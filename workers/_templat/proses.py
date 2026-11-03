"""Logika fitur. Satu-satunya berkas yang perlu diganti saat templat disalin.

proses(event) menerima amplop yang sudah divalidasi dan mengembalikan daftar
(routing_key, data) untuk diterbitkan. Daftar kosong berarti tidak ada event hasil.
Melempar exception berarti gagal: pesan dikembalikan ke queue, dan setelah tiga
percobaan pindah ke DLQ.
"""
import os


def proses(event):
    if os.environ.get('GAGAL_SENGAJA') == '1':
        raise RuntimeError('gagal disengaja untuk menguji DLQ')
    data = event['data']
    if 'puisi_id' not in data:
        raise ValueError('data tanpa puisi_id')
    # contoh hasil untuk worker sungguhan:
    # return [('puisi.dianalisis', {'puisi_id': data['puisi_id'], 'sumber': 'auto-tagging', 'hasil': {...}})]
    return []
