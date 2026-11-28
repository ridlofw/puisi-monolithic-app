# Bukti revisi sisa risiko Hands On 3

Keluaran mentah uji untuk bagian 4.4 [`docs/AUDIT-SPOF-DAN-SKALABILITAS.md`](../AUDIT-SPOF-DAN-SKALABILITAS.md).
Dijalankan 28 November 2026 di Docker Compose laptop Ridlo (Windows 11, Docker Desktop, Docker VM 9,6 GiB,
20 CPU, profile `semua`), branch `ridlo/revisi-handson-3`.

| Berkas | Isi | Perintah |
|---|---|---|
| `phpunit.txt` | PHPUnit poem-service (42 tes) dan search-service (71 tes), termasuk 10 tes `MasterRedis` di masing-masing | `docker compose --profile semua run --rm --no-deps <layanan> vendor/bin/phpunit` |
| `uji-ketahanan-redis.txt` | Tahap Redis: failover, ketiga node mati, stres sambil failover. 12 dari 12 LULUS | `python scripts/uji_ketahanan.py --tahap redis-failover,redis-mati,redis-stres` |
| `uji-ketahanan-penuh.txt` | Semua tahap lama dan baru, 29 dari 29 LULUS | `python scripts/uji_ketahanan.py` |
| `uji-anti-spof.txt` | Enam skenario anti-SPOF, skenario 4 mematikan ketiga node Redis. 6 dari 6 LULUS | `python services/puisi/uji/uji_anti_spof.py` |
| `uji-e2e.txt` | Alur ujung ke ujung, 10 dari 10 LULUS | `python scripts/uji_e2e.py` |
| `sentinel-failover.log` | Baris `+sdown`, `+odown`, `+switch-master`, `+convert-to-slave` dari log `redis-sentinel-1` | `docker compose logs redis-sentinel-1` |
| `ram.txt` | RAM Redis tunggal lama dibanding enam container Redis dan Sentinel | `docker stats --no-stream` |
| `prometheus-redis.txt` | Enam target redis-exporter (3 node, 3 Sentinel) `up`, peran node, master menurut Sentinel, dan nilai query panel hit ratio Grafana | API Prometheus dan Grafana |
| `tarik-image-dry-run.txt` | Rencana `9server.sh tarik` (S3) dalam mode `DRY=1`, tanpa AWS | `DRY=1 bash deploy/aws/9server.sh tarik` |

Waktu di log Sentinel memakai UTC (WIB dikurangi 7 jam). Baris `+sdown master` tanpa `+switch-master`
berasal dari tahap ketiga node Redis dimatikan, saat tidak ada replika yang bisa dipromosikan.

`uji-ketahanan-penuh.txt` dijalankan satu langkah sebelum kode final (objek `MasterRedis` saat itu masih
disimpan statis per proses); tahap Redis diulang di kode final dan hasilnya ada di `uji-ketahanan-redis.txt`.
