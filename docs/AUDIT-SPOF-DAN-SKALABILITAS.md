# Audit SPOF dan Skalabilitas

Dokumen ini menjawab pertanyaan: **apakah sistem ini benar-benar bebas Single Point of Failure
(SPOF), dan apa yang sebenarnya dibuktikan oleh deploy ke satu server?** Tanggal pemeriksaan:
23 November 2026, diperbarui 28 November 2026 untuk revisi sisa risiko Hands On 3 (bagian 4.4: S1 Redis
ditutup, S2 dan S3 masih usulan). Semua angka replika diambil dari konfigurasi Compose yang sebenarnya
(`docker compose --profile semua config`), bukan dari dokumen rancangan.

## 1. Jawaban singkat

| Pertanyaan | Jawaban jujur |
|---|---|
| Apakah bagian Ridlo (poem-service, relay, consumer, database, worker genre) bebas SPOF? | **Ya, pada tingkat software di satu server.** Semuanya punya 2 replika atau lebih, dan database berupa klaster 3 node. |
| Apakah seluruh sistem bebas SPOF? | **Belum.** Ada komponen yang hanya satu (bagian 2), dan satu server EC2 itu sendiri adalah satu titik gagal. |
| Apakah deploy ke satu EC2 bebas SPOF? | **Tidak, dan tidak bisa.** Bila server itu mati, semuanya mati. (Jalur satu server juga **tidak mungkin di sandbox kita**: hanya `t3.small`, 2 GiB.) Deploy yang dipakai adalah 9 server (`PANDUAN-DEPLOY-AWS.md`): satu server pemegang PRIMARY database dimatikan tanpa probe gagal (0 dari 258, saat itu 23 layanan), tetapi SeaweedFS tetap tunggal (Redis kini Redis Sentinel, bagian 4.4). Angka lengkap: `LAPORAN-EKSPERIMEN-AWS.md`. |
| Apakah bisa dibuat bebas SPOF di AWS sandbox? | **Mungkin, tetapi butuh pekerjaan terpisah** yang belum ada: beberapa server di zona berbeda, tumpukan Docker Swarm, dan load balancer (bagian 5). Layanan yang boleh dipakai di sandbox Anda harus dicek dulu. |

## 2. Daftar komponen: mana yang tunggal

Jumlah replika adalah angka dari Compose. "Dampak" ditulis dari membaca kode dan kontrak, kecuali yang
ditandai **diuji** (bagian 4).

| Komponen | Pemilik | Replika | SPOF? | Dampak bila mati | Cara menghilangkannya |
|---|---|---|---|---|---|
| gateway (Nginx) | Pison | 2, pasangan VRRP aktif-pasif (keepalived, VIP 10.231.0.10) | Tidak di tingkat container | gateway-1 mati: VIP pindah ke gateway-2 (**diuji**, tahap `gateway-vip`, 28 Nov: celah terpanjang 4 detik) | Sudah. Di AWS: satu gateway per server pool infra di belakang ALB |
| RabbitMQ | Pison | 3 node, quorum queue | Tidak | Satu node mati: tetap jalan (**diuji**) | Sudah |
| Redis | Pison | 3 node (1 master, 2 replika) + 3 Sentinel | Tidak (S1 ditutup 28 Nov) | Master mati: replika dipromosikan, 0 galat (**diuji**). Ketiga node mati: tetap 200 dari database (**diuji**) | Sudah, bagian 4.4 |
| poem-service | Ridlo | 2 | Tidak | Satu replika mati: tetap jalan (**diuji**) | Sudah |
| poem-relay, poem-consumer | Ridlo | 2 + 2 | Tidak | Pesan menunggu di outbox atau antrean | Sudah |
| poem-db | Ridlo | 3 node + 2 router | Tidak | Primary mati: failover otomatis (**diuji**) | Sudah |
| klasifikasi-genre | Ridlo | 2 | Tidak | Antrean menahan pesan | Sudah |
| auto-tagging | Pison | 2 | Tidak | Antrean menahan pesan | Sudah |
| auth-service | Ifham | 2 | Tidak | | Sudah |
| **auth-db** | Ifham | **1 MySQL** di Compose (di AWS klaster 3 node) | **Ya** di Compose | Login dan daftar gagal. Token yang sudah terbit (berlaku 1 jam) tetap bisa dipakai kirim puisi karena poem-service memeriksa token sendiri | Klaster 3 node seperti poem-db |
| text-to-speech (worker) | Ifham | 2 | Tidak | | Sudah |
| **tts-db** | Ifham | **1 MySQL** | **Ya** (fitur audio) | Audio tidak terbentuk; fitur lain jalan | Klaster 3 node |
| **seaweedfs** | Ifham | **1** | **Ya** (fitur audio) | Audio tidak bisa disimpan atau diputar | Amazon S3 (S2, usulan, bagian 4.4) |
| search-service | Evan | 2 | Tidak | | Sudah |
| search-consumer | Evan | 3 | Tidak | Indeks tertunda; antrean menahan pesan | Sudah |
| **opensearch** | Evan | **1 node** di Compose (di AWS 3 node) | **Ya** di Compose (fitur pencarian) | Pencarian mati; fitur lain jalan | Klaster 3 node (sudah di AWS; di Compose lokal tidak, keterbatasan RAM laptop) |
| **analisis-emosi** | Ray | **1** | Ringan | Hasil emosi tertunda; antrean menahan pesan | Tambah replika |
| **gambar-kutipan** (worker Node.js) | Ray | **tidak ada di Compose** | Tidak tersambung | **Tidak pernah berjalan.** Kodenya ada di `workers/gambar-kutipan/`, tetapi tidak ada layanan Compose-nya dan tidak ada antrean `q.gambar-kutipan` di `rabbitmq/definitions.json` | Tambah fragmen Compose, antrean dan binding di `definitions.json`, dan 2 replika |
| **observability** (Prometheus, Grafana, Loki, dll.) | Ray | **1 masing-masing** | Ya, untuk pemantauan | Pemantauan buta; pengguna tidak terdampak | Replika, atau terima sebagai risiko |
| **registry image** (AWS, server 1) | Ridlo | **1** | Ringan | Task yang dijadwal ulang ke server tanpa image tidak bisa start sampai server 1 hidup | `9server.sh tarik` (S3, bagian 4.4; baru diuji dry-run) |
| **Server (EC2 atau laptop)** | Semua | **1** | **Ya, berat** | Semuanya mati | Beberapa server di zona berbeda |

**Pola yang penting:** layanan berbasis antrean (worker) aman karena RabbitMQ menahan pesan sampai
worker hidup lagi. Yang paling berbahaya adalah komponen di jalur pengguna yang tunggal: di Compose
lokal itu **auth-db** (gateway kini berpasangan VRRP).

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
| Baris 209 (R6): "2 replika Nginx di belakang AWS ALB Multi-AZ" | Di Compose 2 container gateway (VRRP aktif-pasif); di AWS satu gateway per server pool infra di belakang ALB |
| Baris 212 (R9): `uji_anti_spof.py` "6/6 skenario lulus" | **Sesuai.** Saya menjalankannya hari ini: 6 dari 6 lulus |

Baris 210 (R7, observability) hanya menyebut daftar alat dan tidak mengklaim jumlah replika, jadi tidak
ada pertentangan di sana, meskipun semua alatnya memang berjalan tunggal.

Dua cara menyelaraskannya. **Tuliskan dengan jujur** bahwa dokumen menggambarkan rancangan produksi
dan bahwa Compose adalah demo satu server dengan daftar komponen tunggal di atas; **atau perbaiki
implementasinya** (bagian 5). Menuliskan "bebas SPOF" padahal masih ada komponen tunggal berisiko bila ada
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

- Mematikan **auth-db**, **tts-db**, **seaweedfs**, atau **opensearch**. Dari konfigurasi
  jelas keempatnya tunggal, jadi hasilnya sudah dapat diperkirakan: fiturnya berhenti. (Gateway sejak itu
  dijadikan pasangan VRRP dan diuji lewat tahap `gateway-vip` di `scripts/uji_ketahanan.py`.)
- Mematikan satu **server** utuh (hanya mungkin dengan lebih dari satu server).
- Dua kegagalan bersamaan (misalnya Primary database dan satu router sekaligus).
- Pencarian, Text-to-Speech, dan observability **tidak dinyalakan** karena unduhan image di jaringan ini
  sekitar 0,35 MB per detik.

### 4.4 Revisi sisa risiko Hands On 3 (28 November 2026)

Dokumen Hands On 3 menyisakan tiga risiko: **S1** Redis satu node, **S2** SeaweedFS satu node di s7, **S3**
registry image di s1. Semua uji di bawah dijalankan di Docker Compose laptop Ridlo (Docker VM 9,6 GiB,
profile `semua`). Bukti mentah ada di [`bukti-revisi-handson-3/`](bukti-revisi-handson-3/).

| Risiko | Status | Commit | Bukti |
|---|---|---|---|
| S1 Redis satu node | **Ditutup** di Compose; di `stack.yaml` sintaks saja, belum diuji di AWS | `314b2e4`, `cf4b7eb`, `1f4a2e4`, `bfacd50` | PHPUnit, `uji_ketahanan.py` (tahap Redis 12 dari 12, semua tahap 29 dari 29), `uji_anti_spof.py` 6 dari 6, `uji_e2e.py` 10 dari 10 |
| S3 registry di s1 | Skrip siap, **baru diuji dry-run** (tidak ada sesi AWS) | `60adeb7` | `tarik-image-dry-run.txt` |
| S2 SeaweedFS di s7 | **Usulan**, tidak dikerjakan (perlu sesi AWS dan izin S3) | - | - |

**S1, rancangan.** `redis-1..3` (1 master, 2 replika, cache tanpa persistensi, `maxmemory 128mb`) dan
`redis-sentinel-1..3` (kuorum 2, `down-after-milliseconds` 3000). Skrip start `redis/mulai.sh` menanyakan
master saat ini ke Sentinel lain sebelum start, jadi node yang menyala ulang bergabung sebagai replika.
`src/MasterRedis.php` di poem-service dan search-service mencari master: alamat tersimpan (5 detik, di
berkas karena setiap request web adalah proses baru), lalu Sentinel `get-master-addr-by-name`, lalu `ROLE`
di setiap node. Node yang gagal dan keadaan "semua mati" diingat 3 detik. Selama promosi, replika dipakai
untuk membaca saja. Penulisan yang ditolak `READONLY` membuat alamat master dicari ulang.

**S1, hasil uji** (`uji-ketahanan-redis.txt`, kode final):

| Tahap | Hasil |
|---|---|
| Master dihentikan (`docker compose stop`) | Sentinel menunjuk master baru 6,5 detik setelah perintah stop (log Sentinel: `+sdown` sampai `+switch-master` di bawah 1 detik; sisanya `down-after` 3 detik dan waktu stop container) |
| Probe galeri selama failover | 27 probe, 0 galat, semua dari cache Redis (dibaca dari replika), terlama 283 ms |
| Tulis setelah failover | kunci baru: `db` lalu `redis`, jadi cache tertulis ke master baru |
| Master lama dinyalakan lagi | bergabung sebagai replika, klaster kembali 1 master 2 replika |
| Ketiga node Redis mati | 10 dari 10 galeri tetap 200 dari database, median 31 ms, terlama 786 ms (request pertama mencoba tiga node, masing-masing 0,25 detik) |
| Redis menyala lagi | 1 master 2 replika dan galeri kembali dari Redis setelah 1 detik |

**Stres sambil failover** (tahap `redis-stres`; nanti dipindah ke `docs/STRESS-TEST.md`). `uji_stres.py`
40 pengguna selama 45 detik dengan campuran aslinya (cache gateway dan throttling aktif). Master Redis
dihentikan pada detik ke-18.

| Ukuran | Nilai |
|---|---|
| Request | 35.247 (783,3 rps) |
| P50 / P95 / P99 | 46,9 / 72,9 / 84,6 ms |
| Galat (5xx atau koneksi gagal) | **0,00 persen** |
| 429 dari throttling gateway | 21,18 persen (semua pengguna virtual dari satu IP; bukan galat) |
| Master baru | 7,4 detik setelah perintah stop |
| Hit ratio Redis | 55,0 persen sebelum failover (560 baca), 54,4 persen setelah promosi (813 baca) |

Catatan jujur: campuran `uji_stres.py` sebagian besar dijawab cache 10 detik di gateway, jadi hanya
sebagian kecil request yang sampai ke Redis. Bukti bahwa failover Redis sendiri tidak menimbulkan galat
adalah probe yang melewati cache gateway (tabel sebelumnya); angka stres menunjukkan bahwa di bawah beban
pun tidak ada galat.

**S1, tambahan RAM** (`ram.txt`): enam container Redis dan Sentinel memakai 43,6 MiB setelah uji, Redis
tunggal lama 4,98 MiB saat menganggur. Tambahannya sekitar 35 sampai 39 MiB. Batas atas tetap
`maxmemory 128mb` per node, jadi bila cache penuh kedua replika masing-masing bisa memakai sekitar 128 MiB
lagi.

**S1, temuan saat uji** (sudah diperbaiki di commit yang sama):

1. Dengan nama host, Sentinel masuk mode TILT dan **tidak mau failover** begitu nama node yang berhenti
   tidak bisa di-resolve. Di container Debian (poem-service), nama yang hilang juga butuh sekitar 4 detik
   untuk gagal di-resolve, sehingga setiap request menunggu 4 detik saat Redis mati. Perbaikan di Compose:
   semua memakai IP tetap di jaringan `redis-ha` (koneksi ke IP yang mati dibatasi 0,25 detik). Di Swarm
   dipakai nama VIP, yang tetap ter-resolve walau task mati.
2. Saat ketiga node menyala bersamaan, versi pertama `mulai.sh` sempat membuat dua master sekitar 12
   detik sampai Sentinel membereskannya. Perbaikan: node selalu mengikuti master menurut Sentinel bila ada.
3. `CacheTest` lama di search-service ikut terhubung ke Redis sungguhan lewat Sentinel; tes kini juga
   mengosongkan `REDIS_SENTINELS`.

**S3, registry.** `bash deploy/aws/9server.sh tarik` menarik image `localhost:5000` ke setiap server yang
boleh menjalankannya (pool dari tabel `TATA`, ditambah pencarian dan tts tahap 2). `stack deploy` merujuk
image lewat digest, dan Swarm tidak menarik ulang image ber-digest yang sudah ada di server itu, jadi task
yang dijadwal ulang tidak menunggu server 1. `DRY=1` mencetak rencana tanpa memanggil AWS dan memeriksa
bahwa setiap image registry di stack punya pool. Belum dijalankan di AWS. ECR tetap pilihan bila sandbox
mengizinkan, tetapi itu belum terbukti.

**S2, usulan.** Ganti SeaweedFS dengan Amazon S3: worker text-to-speech sudah memakai API S3, jadi yang
berubah terutama `S3_ENDPOINT`, bucket, dan kredensial lewat secret (kunci sandbox bersifat sementara,
perlu token sesi), serta `gateway/rute/audio.conf` yang diarahkan ke S3. Kredensial tidak boleh masuk
repositori. Dikerjakan bila ada sesi AWS Academy dan S3 boleh dipakai.

**Keterbatasan yang tetap.** auth-db, tts-db, dan OpenSearch di Compose lokal masih satu node (di AWS sudah
klaster 3 node); RAM laptop presentasi tidak cukup untuk menjalankannya bersama stack demo. Redis
Sentinel di `stack.yaml` dan skrip `tarik` belum pernah dijalankan di AWS.

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
| Pison | gateway 2 replika (sudah, VRRP), rencana load balancer, Redis replika (sudah, Redis Sentinel 28 Nov) |
| Ifham | klasterkan `auth-db` dan `tts-db`, ganti `seaweedfs` tunggal |
| Evan | OpenSearch beberapa node, `search-consumer` 2 replika |
| Ray | pasang worker `gambar-kutipan` (layanan Compose + antrean di `definitions.json`), `analisis-emosi` 2 replika, putuskan apakah observability perlu redundan |
| Ridlo | sudah memenuhi di tingkat software; ikut menguji skenario kegagalan lintas server |
| Semua | selaraskan kalimat "tanpa SPOF" di dokumen rancangan dengan kenyataan (bagian 3) |
