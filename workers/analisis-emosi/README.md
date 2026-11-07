# Worker Analisis Sentimen dan Emosi

Worker asinkron untuk menganalisis polaritas sentimen dan mendeteksi emosi dominan per bait pada teks puisi berbahasa Indonesia.

## 1. Cara Kerja

Worker mengonsumsi antrean `q.analisis-emosi` yang terikat ke exchange `puisi.events` dengan routing key `puisi.dibuat`. Setelah memproses teks puisi, worker menerbitkan event `puisi.dianalisis` ke topic exchange `puisi.events` dengan struktur data:

```json
{
  "puisi_id": 1,
  "sumber": "analisis-emosi",
  "hasil": {
    "sentimen": {
      "skor": 0.42,
      "label": "positif"
    },
    "emosi_dominan_per_bait": [
      "percaya"
    ]
  }
}
```

Setiap pesan diproses dengan meneruskan `correlation_id` asli dari `X-Request-ID` untuk keterlacakan end-to-end.

### Sifat Asinkron dan Opsional
Worker bersifat lepas (*loosely coupled*). Jika worker dimatikan:
- Pesan event `puisi.dibuat` akan tetap aman tertampung di antrean quorum `q.analisis-emosi`.
- Alur layanan lain (`poem-service`, `search-service`, `text-to-speech`) tidak terganggu sama sekali.
- Begitu worker dijalankan kembali, antrean akan otomatis dikonsumsi hingga habis tanpa kehilangan data.

### Penanganan Kegagalan dan DLQ
Jika terjadi error saat pemrosesan pesan:
- Percobaan pertama dan kedua: Pesan diterbitkan ulang ke antrean dengan header `x-percobaan` yang dinaikkan.
- Percobaan ketiga: Pesan di-reject tanpa requeue dan otomatis dipindahkan oleh `puisi.dlx` ke `q.analisis-emosi.dlq`.

## 2. Menjalankan Worker

### Menjalankan dengan Docker Compose
Worker dapat dijalankan secara terisolasi bersama infrastruktur inti:
```bash
docker compose --profile emosi up -d
```

### Menjalankan secara Mandiri (Lokal Python)
```bash
export AMQP_URLS="amqp://puisi:puisi@localhost:5672/%2F"
export QUEUE="q.analisis-emosi"
export NAMA_WORKER="analisis-emosi"
export PORT_METRIK="9100"
python worker.py
```

## 3. Sumber dan Lisensi Leksikon

Leksikon disimpan dalam format JSON di direktori `leksikon/`:
1. **InSet (Indonesian Sentiment Lexicon)**:
   - Dibuat oleh Muhammad Fajri Koto dan Gemala Y. Rahmaningtyas (2017).
   - Digunakan untuk menentukan polaritas kata positif dan negatif beserta bobot nilainya.
2. **NRC Emotion Lexicon (Terjemahan Bahasa Indonesia)**:
   - Dibuat oleh Saif M. Mohammad dan Peter D. Turney (National Research Council Canada).
   - Memetakan kata ke 8 emosi dasar: `senang` (joy), `percaya` (trust), `takut` (fear), `terkejut` (surprise), `sedih` (sadness), `jijik` (disgust), `marah` (anger), dan `antisipasi` (anticipation).
   - Lisensi: Gratis untuk keperluan riset akademis dan non-komersial.

Leksikon dapat dibangun ulang melalui skrip:
```bash
python bangun_leksikon.py
```

## 4. Pengujian

1. **Unit Test**:
   ```bash
   python -m unittest discover -s tests -v
   ```
2. **Uji Integrasi Event RabbitMQ**:
   - Kirim event contoh:
     ```bash
     python ../../scripts/kirim_event.py puisi.dibuat ../../kontrak/contoh/pantun.json
     ```
   - Intip hasil analisis emosi:
     ```bash
     python ../../scripts/intip_event.py --tipe puisi.dianalisis
     ```
   - Uji DLQ dengan pesan rusak:
     ```bash
     python ../../scripts/kirim_event.py puisi.dibuat ../../kontrak/contoh/rusak.json --mentah
     ```
