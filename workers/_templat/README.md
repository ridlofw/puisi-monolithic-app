# Templat Worker

Kerangka consumer RabbitMQ untuk setiap worker pemrosesan teks. Salin folder ini, lalu ganti
`proses.py` saja.

```
cp -r workers/_templat workers/<fitur>
```

| Berkas | Isi | Diubah? |
|---|---|---|
| `proses.py` | logika fitur, `proses(event)` mengembalikan daftar `(routing_key, data)` | ya |
| `worker.py` | koneksi ke klaster, ack, ulang, DLQ, log JSON | tidak |
| `amplop.py` | bentuk amplop event dari `kontrak/README.md` | tidak |
| `metrik.py` | `/metrics` di port 9100: diproses, gagal, histogram durasi | tidak |
| `tests/` | unittest, tambahkan tes fitur di sini | ya |

## Perilaku yang sudah ditangani

- **Gagal diulang, lalu DLQ.** Exception di `proses()` membuat pesan diterbitkan ulang dengan jeda
  1 lalu 2 detik. Pada percobaan ketiga pesan di-reject dan pindah ke `q.<nama>.dlq`. Alasannya ada
  di bagian Queue pada `kontrak/README.md`.
- **Failover broker.** Node di `AMQP_URLS` dicoba berurutan. Saat node yang dipakai mati, worker
  pindah ke node lain dalam beberapa detik tanpa kehilangan pesan.
- **Hasil tidak terbit berarti belum selesai.** Bila menerbitkan event hasil gagal, pesan asal
  diulang, bukan di-ack.
- **Prefetch 1**, jadi beberapa replika berbagi beban secara merata.

## Menjalankan

```
python -m unittest discover -s tests                            # dari folder worker
docker compose --profile templat up --build                     # templat sebagai worker contoh
TEMPLAT_GAGAL=1 docker compose --profile templat up -d          # selalu gagal, untuk menguji DLQ
```

| Variabel | Arti |
|---|---|
| `AMQP_URLS` | node RabbitMQ dipisah koma, lihat `kontrak/README.md` |
| `QUEUE` | queue yang dikonsumsi |
| `NAMA_WORKER` | label pada log dan metrik |
| `PORT_METRIK` | bawaan 9100 |

Pustaka tambahan cukup ditulis di `requirements.txt`. `pika` sudah ada.
