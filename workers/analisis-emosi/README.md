# Worker Analisis Sentimen dan Emosi

Worker asinkron untuk menganalisis polaritas sentimen dan mendeteksi emosi dominan per bait pada teks puisi berbahasa Indonesia.

## 1. Cara Kerja

Worker mengonsumsi antrean `q.analisis-emosi` yang terikat ke exchange `puisi.events` dengan routing key `puisi.dibuat`. Setelah memproses teks puisi, worker menerbitkan event `puisi.dianalisis` dengan payload:

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

### Tahapan Pemrosesan:
1. **Praproses**: Pembersihan tanda baca, normalisasi huruf kecil, pemisahan bait (berdasarkan baris kosong), dan tokenisasi kata.
2. **Penanganan Negasi**: Kata negasi (`tidak`, `bukan`, `tak`, `tiada`, `belum`, `kurang`) membalik nilai polaritas sentimen kata sesudahnya.
3. **Pencocokan Leksikon Bertahap**:
   - Kata asli diperiksa terlebih dahulu pada leksikon polaritas dan emosi.
   - Stemming PySastrawi hanya dipanggil jika kata asli tidak ditemukan di leksikon, sehingga proses tetap cepat dan efisien.
4. **Perhitungan Sentimen**: Rata-rata skor kata berbobot pada rentang `[-1.0, 1.0]`. Label bernilai `positif` jika skor > 0.05, `negatif` jika skor < -0.05, dan `netral` di antaranya.
5. **Penentuan Emosi Dominan per Bait**: Menghitung frekuensi kemunculan 8 emosi dasar pada setiap bait. Emosi dengan bobot terbesar menjadi emosi dominan bait tersebut.

## 2. Sumber dan Lisensi Leksikon

Leksikon disimpan dalam format JSON di direktori `leksikon/`:
1. **InSet (Indonesian Sentiment Lexicon)**:
   - Dibuat oleh Muhammad Fajri Koto dan Gemala Y. Rahmaningtyas (2017).
   - Digunakan untuk menentukan polaritas kata positif dan negatif beserta bobot nilainya.
2. **NRC Emotion Lexicon (Terjemahan Bahasa Indonesia)**:
   - Dibuat oleh Saif M. Mohammad dan Peter D. Turney (National Research Council Canada).
   - Memetakan kata ke 8 emosi dasar: `senang` (joy), `percaya` (trust), `takut` (fear), `terkejut` (surprise), `sedih` (sadness), `jijik` (disgust), `marah` (anger), dan `antisipasi` (anticipation).
   - Lisensi: Gratis untuk keperluan riset akademis dan non-komersial.

Leksikon dapat diperbarui atau dibangun ulang melalui skrip:
```bash
python bangun_leksikon.py
```

## 3. Pengujian

Menjalankan seluruh unit test worker dan analisis emosi:
```bash
python -m unittest discover -s tests -v
```
Semua kasus uji mencakup pembersihan teks, pembalikan kata negasi, penanganan puisi netral, serta verifikasi keluaran terhadap contoh puisi pantun, syair, dan gurindam.
