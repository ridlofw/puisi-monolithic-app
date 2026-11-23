# SLI, SLO, dan Batas Kemampuan

Target keandalan aplikasi puisi beserta cara mengukurnya (Bab 11.7) dan hasil stress test yang
menunjukkan sampai mana target itu bertahan (Bab 10.5).

## SLI dan SLO

| SLI | Cara ukur | SLO | Alert |
|---|---|---|---|
| Ketersediaan API | `sum(rate(puisi_http_requests_total{status!~"5.."}[30d])) / sum(rate(puisi_http_requests_total[30d]))` dan `probe_success` blackbox | 99,5 persen per 30 hari | `LayananTidakMenjawab` |
| Latensi API | P99 `puisi_http_durasi_detik` per rute | P99 di bawah 500 ms | `LatensiP99Tinggi` |
| Kesegaran hasil asinkron | panjang antrean per queue dan P99 `worker_durasi_detik` | antrean di bawah 100 pesan, P99 worker di bawah 10 s | `AntrianMenumpuk`, `WorkerP99Lambat` |
| Kebenaran pemrosesan | rasio pesan gagal per worker, isi DLQ | gagal di bawah 10 persen, DLQ kosong | `WorkerGagal`, `DLQTidakKosong` |

**Error budget.** SLO 99,5 persen per 30 hari memberi anggaran 0,5 persen x 43.200 menit = **216 menit**
gangguan per bulan. Selama anggaran masih ada, fitur baru boleh dirilis; bila habis, prioritas pindah ke
ketahanan, misalnya gateway ganda dan auth-db klaster.

**SLA** tidak ditetapkan. Aplikasi ini proyek kuliah tanpa pelanggan berbayar; SLO di atas adalah target
internal tim.

## Stress test

`python scripts/uji_stres.py` menaikkan pengguna virtual bertahap, masing-masing tanpa jeda, dengan campuran
50 persen galeri, 25 persen detail, dan 25 persen pencarian kata acak. Hasil 23 November 2026, stack
`--profile semua` di satu laptop 12 core, klien di mesin yang sama:

| Pengguna | rps | P50 ms | P95 ms | P99 ms | Galat | SLO |
|---|---|---|---|---|---|---|
| 1 | 205,8 | 3,5 | 9,7 | 23,5 | 0 % | ok |
| 5 | 687,3 | 5,2 | 18,9 | 27,2 | 0 % | ok |
| 10 | 846,4 | 9,6 | 24,5 | 33,4 | 0 % | ok |
| 20 | 843,2 | 20,9 | 41,3 | 59,6 | 0 % | ok |
| 40 | 907,0 | 41,6 | 62,5 | 82,5 | 0 % | ok |
| 80 | 861,0 | 87,8 | 129,5 | 151,9 | 0 % | ok |
| 160 | 874,6 | 180,7 | 219,9 | 250,4 | 0 % | ok |
| 320 | 812,4 | 389,5 | 484,1 | 557,3 | 0 % | **melanggar** |

- **Titik jenuh** ada di sekitar 10 pengguna: throughput berhenti naik di kisaran 850 sampai 900 rps dan
  setiap tambahan pengguna hanya menambah antrean, sehingga latensi naik lurus.
- **Titik hancur SLO** ada di antara 160 dan 320 pengguna: P99 melewati 500 ms. Tidak ada galat 5xx di
  tahap mana pun; sistem melambat, bukan rusak.
- **Bottleneck**: saat 80 pengguna, OpenSearch memakai 113 persen CPU, jauh di atas komponen lain
  (gateway 47 persen, poem-service sekitar 18 persen per replika). Pencarian yang tidak tertolong cache
  membebani node OpenSearch tunggal, komponen yang juga menjadi titik gagal tunggal. Tiga node OpenSearch
  menyelesaikan keduanya.
