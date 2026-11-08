# Auto-tagging

Lima kata kunci dan satu kategori dari judul dan isi puisi. Disalin dari `workers/_templat/`,
jadi `worker.py`, `amplop.py`, dan `metrik.py` tidak diubah. Pemilik: Pison.

Hasilnya berbentuk `{keyword: [lima kata dasar], kategori}` sesuai `kontrak/README.md`.

## Cara kerja

| Berkas | Isi |
|---|---|
| `praproses.py` | huruf kecil, buang tanda baca dan angka, tokenisasi, stopword, stemming Sastrawi, stopword lagi |
| `tfidf.py` | skor TF-IDF terhadap korpus rujukan, lima teratas |
| `kategori.py` | lima kata kunci dicocokkan ke leksikon enam kategori |
| `tagging.py` | gabungan ketiganya, `analisis(judul, isi)` |
| `korpus/puisi.txt` | 40 puisi pendek rujukan, dipisah baris `---` |
| `df.json` | jumlah puisi korpus yang memuat setiap kata dasar, hasil `bangun_df.py` |

- **Stopword dua kali.** Daftar Sastrawi ditambah kata ganti puisi seperti `engkau` dan `kau`,
  serta `barang` dan `sepenuh` dari frasa baku *barang siapa* dan *sepenuh hati*. Penyaringan
  diulang setelah stemming, karena `bersama` baru
  menjadi stopword `sama` setelah di-stem. Kata dasar di bawah tiga huruf dibuang.
- **IDF dari korpus yang dibundel**, `ln((1 + N) / (1 + df)) + 1`. Kata di luar korpus mendapat IDF
  maksimum. Korpus tidak berubah saat worker berjalan, jadi worker stateless dan puisi yang sama
  selalu menghasilkan kata kunci yang sama di replika mana pun.
- **Skor seri diputus oleh kemunculan pertama.** Judul diletakkan di depan isi, jadi kata dari
  judul didahulukan. Pada puisi pendek, banyak kata muncul sekali dan skornya sama persis.
- **Kategori**: cinta, alam, ketuhanan, perjuangan, kesedihan, sosial. Kata kunci peringkat pertama
  berbobot 5 sampai peringkat kelima berbobot 1. Bobot terbesar menang, seri diputus menurut
  urutan kategori tersebut. Tanpa kecocokan, kategorinya `umum`.

Sastrawi tidak sempurna. `terasa` di-stem menjadi `asa`, dan `baik` serta `bulan` termasuk stopword
bawaannya. Kata leksikon diuji agar selalu berupa kata dasar dan bukan stopword, sehingga
setiap kata di sana memang bisa cocok.

## Sebagai worker

Mengonsumsi `q.auto-tagging` (binding `puisi.dibuat`) dan menerbitkan `puisi.dianalisis` dengan
`sumber: auto-tagging`, meneruskan `correlation_id` event asal.

| Masukan | Perilaku |
|---|---|
| `data` tanpa `puisi_id`, atau `isi` bukan teks | gagal, diulang dua kali, lalu masuk `q.auto-tagging.dlq` |
| body bukan amplop yang sah | sama, masuk DLQ setelah tiga percobaan |
| `isi` kosong | bukan kegagalan, hasilnya `{keyword: [], kategori: umum}` |
| `judul` null | diterima, hanya `isi` yang dihitung |
| event yang sama dua kali | hasil identik, karena hanya bergantung pada isi event dan `df.json` |

```
docker compose --profile auto-tagging up -d --build              # dua replika
python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json
python scripts/intip_event.py --tipe puisi.dianalisis --tunggu 5
docker compose --profile auto-tagging up -d --scale auto-tagging=3
```

Dua replika dijalankan secara bawaan lewat `deploy.replicas` di `compose/auto-tagging.yaml`.
Prefetch 1 membuat replika berbagi pesan secara bergiliran. Metrik ada di port 9100 setiap
container dan ditemukan Prometheus lewat label `metrics.scrape`.

## Mengubah korpus atau leksikon

```
python bangun_df.py                       # setelah korpus/puisi.txt diubah
python -m unittest discover -s tests      # dari folder ini
```

`tests/test_regresi.py` menetapkan hasil keempat puisi di `kontrak/contoh/` dan memastikan `df.json`
sama dengan hasil membangun ulang dari korpus. Bila hasil berubah karena korpus atau leksikon
diubah dengan sengaja, periksa hasil barunya, lalu perbarui harapan di tes itu dan
`kontrak/contoh/dianalisis.auto-tagging.json`.

Tes dijalankan dari host, bukan dari image, karena tes regresi membaca `kontrak/contoh/`.
Pustaka tambahan: `PySastrawi==1.2.1`, dikunci agar hasil stemming sama di setiap mesin.
