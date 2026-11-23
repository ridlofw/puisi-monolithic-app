# Audit SPOF dan Skalabilitas

Dokumen ini menjawab pertanyaan: **apakah sistem ini benar-benar bebas Single Point of Failure
(SPOF), dan apa yang sebenarnya dibuktikan oleh deploy ke satu server?** Tanggal pemeriksaan:
23 November 2026. Semua angka replika diambil dari konfigurasi Compose yang sebenarnya
(`docker compose --profile semua config`), bukan dari dokumen rancangan.

## 1. Jawaban singkat

| Pertanyaan | Jawaban jujur |
|---|---|
| Apakah bagian Ridlo (poem-service, relay, consumer, database, worker genre) bebas SPOF? | **Ya, pada tingkat software di satu server.** Semuanya punya 2 replika atau lebih, dan database berupa klaster 3 node. |
| Apakah seluruh sistem bebas SPOF? | **Belum.** Ada komponen yang hanya satu (bagian 2), dan satu server EC2 itu sendiri adalah satu titik gagal. |
| Apakah deploy ke satu EC2 bebas SPOF? | **Tidak, dan tidak bisa.** Bila server itu mati, semuanya mati. (Jalur satu server juga **tidak mungkin di sandbox kita**: hanya `t3.small`, 2 GiB.) Deploy yang dipakai adalah 9 server (`PANDUAN-DEPLOY-AWS.md`): satu server pemegang PRIMARY database dimatikan tanpa probe gagal (0 dari 258, saat itu 23 layanan), tetapi SeaweedFS dan Redis tetap tunggal. Angka lengkap: `LAPORAN-EKSPERIMEN-AWS.md`. |
| Apakah bisa dibuat bebas SPOF di AWS sandbox? | **Mungkin, tetapi butuh pekerjaan terpisah** yang belum ada: beberapa server di zona berbeda, tumpukan Docker Swarm, dan load balancer (bagian 5). Layanan yang boleh dipakai di sandbox Anda harus dicek dulu. |

## 2. Daftar komponen: mana yang tunggal

Jumlah replika adalah angka dari Compose. "Dampak" ditulis dari membaca kode dan kontrak, kecuali yang
ditandai **diuji** (bagian 4).

| Komponen | Pemilik | Replika | SPOF? | Dampak bila mati | Cara menghilangkannya |
|---|---|---|---|---|---|
| **gateway (Nginx)** | Pison | **1** | **Ya, berat** | Seluruh akses masuk ke aplikasi putus | Minimal 2 replika di server berbeda di belakang load balancer |
| RabbitMQ | Pison | 3 node, quorum queue | Tidak | Satu node mati: tetap jalan (**diuji**) | Sudah |
| **Redis** | Pison | **1** | Ringan | Hanya lebih lambat; kode tetap membaca dari database (**diuji**) | Replika Redis dengan Sentinel, atau layanan terkelola |
| poem-service | Ridlo | 2 | Tidak | Satu replika mati: tetap jalan (**diuji**) | Sudah |
| poem-relay, poem-consumer | Ridlo | 2 + 2 | Tidak | Pesan menunggu di outbox atau antrean | Sudah |
| poem-db | Ridlo | 3 node + 2 router | Tidak | Primary mati: failover otomatis (**diuji**) | Sudah |
| klasifikasi-genre | Ridlo | 2 | Tidak | Antrean menahan pesan | Sudah |
| auto-tagging | Pison | 2 | Tidak | Antrean menahan pesan | Sudah |
| auth-service | Ifham | 2 | Tidak | | Sudah |
| **auth-db** | Ifham | **1 MySQL** | **Ya** | Login dan daftar gagal. Token yang sudah terbit (berlaku 1 jam) tetap bisa dipakai kirim puisi karena poem-service memeriksa token sendiri | Klaster 3 node seperti poem-db |
| text-to-speech (worker) | Ifham | 2 | Tidak | | Sudah |
| **tts-db** | Ifham | **1 MySQL** | **Ya** (fitur audio) | Audio tidak terbentuk; fitur lain jalan | Klaster 3 node |
| **seaweedfs** | Ifham | **1** | **Ya** (fitur audio) | Audio tidak bisa disimpan atau diputar | Replika SeaweedFS, atau Amazon S3 |
| search-service | Evan | 2 | Tidak | | Sudah |
| **search-consumer** | Evan | **1** | Ringan | Indeks tertunda; antrean menahan pesan | Tambah replika |
| **opensearch** | Evan | **1 node** | **Ya** (fitur pencarian) | Pencarian mati; fitur lain jalan | Klaster 3 node |
| **analisis-emosi** | Ray | **1** | Ringan | Hasil emosi tertunda; antrean menahan pesan | Tambah replika |
| **gambar-kutipan** (worker Node.js) | Ray | **tidak ada di Compose** | Tidak tersambung | **Tidak pernah berjalan.** Kodenya ada di `workers/gambar-kutipan/`, tetapi tidak ada layanan Compose-nya dan tidak ada antrean `q.gambar-kutipan` di `rabbitmq/definitions.json` | Tambah fragmen Compose, antrean dan binding di `definitions.json`, dan 2 replika |
| **observability** (Prometheus, Grafana, Loki, dll.) | Ray | **1 masing-masing** | Ya, untuk pemantauan | Pemantauan buta; pengguna tidak terdampak | Replika, atau terima sebagai risiko |
| **Server (EC2 atau laptop)** | Semua | **1** | **Ya, berat** | Semuanya mati | Beberapa server di zona berbeda |

**Pola yang penting:** layanan berbasis antrean (worker) aman karena RabbitMQ menahan pesan sampai
worker hidup lagi. Yang paling berbahaya adalah komponen di jalur pengguna yang tunggal: **gateway**
dan **auth-db**.

## 3. Perbedaan dengan dokumen rancangan kelompok

`Tugas Kelompok Scalable - Grup C.md` menyatakan beberapa hal yang **tidak sama** dengan Compose saat ini.
Sebaiknya kelompok menyelaraskannya sebelum dikumpulkan:

| Pernyataan di dokumen rancangan | Kenyataan di Compose |
|---|---|
| Baris 36: lapisan MVP "tidak memiliki single point of failure" | Ada komponen tunggal (bagian 2) |
| Baris 198: R1 sampai R10 terpenuhi "tanpa single point of failure" | Sama |
| Baris 204 (R1): `auth-service`, `poem-service`, `search-service`, `poem-relay`, `poem-consumer` "minimal 2 replika" | **Sesuai.** Kelimanya berreplika 2 |
| Baris 205 (R2): daftar worker termasuk `workers/gambar-kutipan`, dan "setiap worker berjalan 2 replika" | **Tidak sesuai untuk dua hal.** `analisis-emosi` hanya 1 replika, dan `gambar-kutipan` **tidak ada di Compose sama sekali** |
| Baris 208 (R5): `auth-db`, `poem-db`, `tts-db`, `opensearch` terpisah | Terpisah, tetapi `auth-db`, `tts-db`, dan `opensearch` masing-masing tunggal |
| Baris 209 (R6): "2 replika Nginx di belakang AWS ALB Multi-AZ" | `gateway` hanya 1 container, tanpa load balancer |
| Baris 212 (R9): `uji_anti_spof.py` "6/6 skenario lulus" | **Sesuai.** Saya menjalankannya hari ini: 6 dari 6 lulus |

Baris 210 (R7, observability) hanya menyebut daftar alat dan tidak mengklaim jumlah replika, jadi tidak
ada pertentangan di sana, meskipun semua alatnya memang berjalan tunggal.

Dua cara menyelaraskannya. **Tuliskan dengan jujur** bahwa dokumen menggambarkan rancangan produksi
dan bahwa Compose adalah demo satu server dengan daftar komponen tunggal di atas; **atau perbaiki
implementasinya** (bagian 5). Menuliskan "bebas SPOF" padahal ada gateway tunggal berisiko bila ada
yang memeriksa konfigurasinya.

## 4. Hasil uji ketahanan hari ini

### 4.1 Uji anti-SPOF resmi: 6 dari 6 LULUS

Dijalankan dengan `python services/puisi/uji/uji_anti_spof.py` (skrip mematikan komponen satu per satu
lalu memulihkannya):

| # | Kegagalan yang disimulasikan | Hasil yang diamati | Status |
|---|---|---|---|
| 1 | Satu replika `poem-service` mati | `POST` 202, `GET` 200 lewat replika lain | LULUS |
| 2 | Satu router database (`poem-db-router-1`) mati | `POST` 202, `GET` 200 lewat router-2 | LULUS |
| 3 | **Node Primary database mati** (`poem-db-1`) | failover otomatis ke `poem-db-3`, `POST` 202, `GET` 200 | LULUS |
| 4 | Redis mati | `GET` 200 dengan `X-Cache-Layer: db` (turun ke database) | LULUS |
| 5 | Satu node RabbitMQ mati (`rabbitmq-2`) | `POST` 202, event outbox tetap terkirim | LULUS |
| 6 | **Seluruh RabbitMQ mati**, lalu dinyalakan | `POST` 202 saat broker mati, event terkirim setelah broker hidup | LULUS |

Setelah uji: ketiga node database `ONLINE` (Primary kini `poem-db-3`), ketiga node RabbitMQ berjalan, dan
semua consumer terpasang kembali. Puisi nomor 73 dikirim **ketika seluruh RabbitMQ mati**, dan akhirnya
berstatus `selesai` (kategori, keyword, dan genre terisi).

### 4.2 Uji skalabilitas: menambah replika

`docker compose --profile puisi up -d --no-deps --scale poem-service=4 poem-service` menambah replika dari
2 menjadi 4. Gateway menemukan replika baru lewat nama dan membagi beban sendiri:

| Replika | Permintaan yang dilayani (dari 80) |
|---|---|
| 172.19.0.16 | 25 |
| 172.19.0.17 | 13 |
| 172.19.0.26 (baru) | 22 |
| 172.19.0.27 (baru) | 20 |

Semua 80 permintaan sukses. Jumlah replika lalu dikembalikan ke 2. Ini membuktikan **skalabilitas
horizontal poem-service di satu server**. Untuk penambahan di server lain dibutuhkan Swarm (bagian 5).

### 4.3 Yang tidak diuji

- Mematikan **gateway**, **auth-db**, **tts-db**, **seaweedfs**, atau **opensearch**. Dari konfigurasi
  jelas keempatnya tunggal, jadi hasilnya sudah dapat diperkirakan: fiturnya berhenti.
- Mematikan satu **server** utuh (hanya mungkin dengan lebih dari satu server).
- Dua kegagalan bersamaan (misalnya Primary database dan satu router sekaligus).
- Pencarian, Text-to-Speech, dan observability **tidak dinyalakan** karena unduhan image di jaringan ini
  sekitar 0,35 MB per detik.

## 5. Jalan menuju bebas SPOF di AWS

Bagian ini adalah **peta jalan, belum dikerjakan dan belum diuji**. Saya tidak bisa mengaksesnya
dari sini, jadi jangan menganggapnya sudah terbukti.

**Prinsip:** bebas SPOF berarti setiap komponen punya cadangan **di server berbeda**. Satu server
dengan banyak container hanya melindungi dari matinya container, bukan matinya server.

Rancangan targetnya:

1. **Minimal 3 server EC2 di 3 zona (AZ) berbeda.** Anda tidak bisa memilih region, tetapi biasanya
   tetap bisa memilih zona lewat pilihan subnet. Periksa batas jumlah server dan total vCPU di
   sandbox Anda.
2. **Docker Swarm** menghubungkan ketiga server menjadi satu klaster dan menyebar replika otomatis.
3. **Load balancer** (misalnya AWS Application Load Balancer, bila sandbox mengizinkan) di depan
   minimal 2 replika gateway di server berbeda.
4. **Sebar komponen berklaster satu per server**: tiap node `poem-db`, tiap node RabbitMQ, tiap node
   OpenSearch berada di server berbeda.
5. **Klasterkan komponen yang masih tunggal**: `auth-db`, `tts-db`, penyimpanan audio, OpenSearch, dan
   gateway.

Pekerjaan yang harus dilakukan (belum ada di repo):

- **Menyusun ulang Compose menjadi berkas stack Swarm.** Swarm tidak mendukung `build:`, `include:`,
  `profiles:`, dan syarat `depends_on` seperti di Compose. Image harus diunggah ke registry (misalnya
  ECR, bila sandbox mengizinkan) dan urutan start harus ditangani lain.
- **Membuka port antar-server** untuk Swarm (2377/tcp, 7946/tcp+udp, 4789/udp) di Security Group, hanya
  antar server itu sendiri.
- **Menjamin data tetap di server yang sama** untuk volume database (pin per server).
- **Menguji dengan mematikan satu server sungguhan** dan memastikan semuanya tetap melayani.

Folder `deploy/` **sudah menjalankan arah ini di AWS sandbox** (9 server, 3 zona, Docker Swarm, ALB; hasil dan batasnya di
`LAPORAN-EKSPERIMEN-AWS.md`). Draf lama yang tidak berfungsi (RDS, ElastiCache, Amazon MQ) sudah dihapus.

## 6. Saran pembagian kerja

| Pemilik | Pekerjaan agar bebas SPOF |
|---|---|
| Pison | gateway 2 replika, rencana load balancer, Redis replika (opsional) |
| Ifham | klasterkan `auth-db` dan `tts-db`, ganti `seaweedfs` tunggal |
| Evan | OpenSearch beberapa node, `search-consumer` 2 replika |
| Ray | pasang worker `gambar-kutipan` (layanan Compose + antrean di `definitions.json`), `analisis-emosi` 2 replika, putuskan apakah observability perlu redundan |
| Ridlo | sudah memenuhi di tingkat software; ikut menguji skenario kegagalan lintas server |
| Semua | selaraskan kalimat "tanpa SPOF" di dokumen rancangan dengan kenyataan (bagian 3) |
