# Lapisan Observability Terdistribusi

Lapisan pemantauan sistem, penelusuran log terdistribusi, dan peringatan SLO untuk Aplikasi Publikasi Karya Sastra Puisi.

## 1. Komponen Arsitektur

Observability stack terdiri dari kumpulan komponen yang dideklarasikan pada `compose/observability.yaml`:

1. **Prometheus (:9090)**:
   - Mengumpulkan metrik sistem secara periodik setiap 15 detik.
   - Menggunakan `docker_sd_configs` untuk menemukan seluruh container yang memiliki label `metrics.scrape: "true"` dan port `metrics.port`.
   - Mengikis target statis untuk klaster RabbitMQ (port `15692`), Nginx Prometheus Exporter, Redis Exporter, cAdvisor, dan Blackbox Exporter.
2. **Alertmanager (:9093)**:
   - Mengelola dan merutekan peringatan saat terjadi pelanggaran ambang batas SLO.
3. **Blackbox Exporter (:9115)**:
   - Melakukan probe HTTP berkala ke endpoint publik gateway (`/api/puisi` dan `/api/search`) setiap 15 detik untuk memantau ketersediaan dan latensi respon.
4. **Nginx Prometheus Exporter (:9113)**:
   - Membaca metrik koneksi dan throughput Nginx dari endpoint internal `/stub_status` yang dideklarasikan di `gateway/rute/status.conf`.
5. **Redis Exporter (:9121)**:
   - Memantau penggunaan memori, jumlah koneksi, dan rasio hits/misses cache Redis.
6. **cAdvisor (:8080)**:
   - Memantau pemakaian CPU, memory, network I/O dari setiap container Docker secara real-time.
7. **Loki (:3100) & Promtail**:
   - Promtail mengumpulkan log container Docker, mem-parsing format JSON, serta mengekstrak atribut `level`, `worker`, dan `correlation_id`.
   - Loki mengindeks log sehingga seluruh jejak alur request sebuah puisi dapat ditelusuri dari awal hingga akhir.
8. **Grafana (:3000)**:
   - Menyediakan visualisasi metrik dan log secara terpadu melalui dasbor otomatis (*provisioned dashboard*).
   - Kredensial default: `admin` / `admin`.

## 2. Aturan Alert dan Target SLO

Aturan alert didefinisikan pada `observability/prometheus/alerts.yml`:

| Nama Alert | Kondisi Evaluasi | Durasi | Tingkat | Keterangan |
|---|---|---|---|---|
| `AntrianMenumpuk` | `rabbitmq_queue_messages_ready > 100` | 2 menit | warning | Menandakan beban antrean menumpuk dan worker butuh penambahan skala |
| `DLQTidakKosong` | `rabbitmq_queue_messages{queue=~".*\\.dlq"} > 0` | 1 menit | critical | Ada pesan yang gagal diproses 3 kali dan masuk antrean DLQ |
| `LayananTidakMenjawab`| `probe_success == 0` | 1 menit | critical | Endpoint gateway tidak merespons probe HTTP |
| `LatensiTinggi` | `probe_duration_seconds > 0.5` | 5 menit | warning | Latensi respons gateway melebihi target batas SLO 500ms |
| `WorkerGagal` | Rasio gagal worker > 10% | 2 menit | warning | Worker mengalami tingkat kegagalan komputasi tinggi |

## 3. Provisioning Grafana

- **Datasource Otomatis**: Prometheus (default) dan Loki langsung terdaftar melalui `provisioning/datasources/datasources.yml`.
- **Dasbor Utama**: `puisi_overview.json` menampilkan:
  1. Panjang antrean per queue RabbitMQ.
  2. Laju throughput pesan sukses dan gagal per worker.
  3. Latensi probe gateway Blackbox.
  4. Hit ratio cache Redis.
  5. Penggunaan CPU per container.
  6. Panel log Loki interaktif yang dilengkapi variabel filter `$correlation_id`.

## 4. Cara Menjalankan

Menjalankan seluruh stack observabilitas bersama infrastruktur dasar:
```bash
docker compose --profile observability up -d
```

Atau menjalankan seluruh stack aplikasi lengkap:
```bash
docker compose --profile semua up -d
```
