# Klasifikasi Genre

Penentuan bentuk puisi (`pantun`, `syair`, `gurindam`, atau `puisi bebas`) beserta skema rimanya
dari jumlah baris dan bunyi akhir tiap baris. Disalin dari `workers/_templat/`, sehingga
`worker.py`, `amplop.py`, dan `metrik.py` tidak diubah. Pemilik: Ridlo.

Hasilnya berbentuk `{genre, skema_rima}` sesuai `kontrak/README.md`.

## Cara kerja

| Berkas | Isi |
|---|---|
| `genre.py` | pemisahan bait (`pisah_bait`), bunyi akhir (`bunyi_akhir`), skema bait (`skema_bait`), dan aturan genre (`klasifikasi`) |
| `proses.py` | penghubung amplop event `puisi.dibuat` ke `genre.klasifikasi()` dan penerbitan `puisi.dianalisis` |
| `tests/test_genre.py` | unit test bunyi akhir, skema rima, tiga contoh tiap genre, kasus tepi, dan regresi `kontrak/contoh/` |
| `tests/test_worker.py` | unit test amplop, metrik, retry `x-percobaan`, dan DLQ |

- **Pemisahan bait.** Bait dipisahkan oleh satu atau lebih baris kosong (`\n\n` maupun `\r\n\r\n`).
  Baris kosong di awal/akhir naskah diabaikan.
- **Bunyi akhir baris.** Kata alfabet terakhir diambil dalam huruf kecil tanpa tanda baca dan angka,
  lalu diambil vokal terakhir (`a, i, u, e, o`) beserta seluruh konsonan sesudahnya. Misalnya
  `padi,` dan `hati` sama-sama berbunyi akhir `i`, `pinang` dan `tenang.` sama-sama `ang`, serta
  `jalan` dan `bulan` sama-sama `an`.
- **Skema rima per bait.** Bunyi akhir unik di dalam satu bait dipetakan berurutan ke `a`, `b`, `c`,
  dan seterusnya. Untuk puisi lebih dari satu bait, skema antar-bait digabung dengan spasi
  (contoh: `aa aa`).
- **Aturan klasifikasi:**
  - semua bait 4 baris dengan skema `abab` -> `pantun`
  - semua bait 4 baris dengan skema `aaaa` -> `syair`
  - semua bait 2 baris dengan skema `aa` -> `gurindam`
  - selain ketiganya -> `puisi bebas`

## Sebagai worker

Mengonsumsi `q.klasifikasi-genre` (binding `puisi.dibuat`) dan menerbitkan `puisi.dianalisis`
dengan `sumber: klasifikasi-genre`, meneruskan `correlation_id` event asal.

| Masukan | Perilaku |
|---|---|
| `data` tanpa `puisi_id`, atau `isi` bukan teks | gagal, diulang dua kali, lalu masuk `q.klasifikasi-genre.dlq` |
| body bukan amplop yang sah | sama, masuk DLQ setelah tiga percobaan |
| `isi` kosong | bukan kegagalan, hasilnya `{genre: "puisi bebas", skema_rima: ""}` |
| event yang sama dua kali | hasil identik dan deterministik |

```bash
docker compose --profile genre up -d --build                        # dua replika
python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json
python scripts/intip_event.py --tipe puisi.dianalisis --tunggu 5
docker compose --profile genre up -d --scale klasifikasi-genre=3
```

## Pengujian

```bash
python -m unittest discover -s workers/klasifikasi-genre/tests -v
```
