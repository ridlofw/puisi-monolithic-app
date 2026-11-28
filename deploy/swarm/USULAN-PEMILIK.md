# Usulan per pemilik: menghilangkan komponen tunggal

[`kontrak/README.md`](../../kontrak/README.md) menetapkan **satu fragmen Compose per pemilik**. Karena itu
[`stack.yaml`](stack.yaml) **tidak mengubah** fragmen siapa pun, dan perubahan yang menyentuh kode atau
berkas milik teman hanya ditulis sebagai **usulan** di sini. Setiap pemilik memutuskan sendiri.

Semua usulan di bawah **belum diuji**. Yang sudah saya periksa tertulis jelas ("diperiksa") dan
bedanya dengan "dari membaca kode" juga ditandai.

> **Siapa yang perlu membaca ini?** Dokumen ini ditujukan kepada **teman satu tim pemilik komponen**
> (Pison, Ifham, Evan, Ray), bukan untuk pemula yang sedang belajar men-deploy. Bila Anda pemula,
> baca [`panduan/`](panduan/) lebih dulu; istilah seperti *SPOF*, *replika*, *klaster*, dan *quorum*
> dijelaskan di [`panduan/1-konsep-dasar.md`](panduan/1-konsep-dasar.md) dan
> [`panduan/2-antar-microservice.md`](panduan/2-antar-microservice.md).
>
> **Pembaruan 23 November 2026 (baca ini dulu).** Sebagian besar usulan di bawah **sudah dikerjakan di
> sisi deploy** (`stack.yaml`, skrip, dan konfigurasi milik Ridlo), tanpa mengubah berkas milik teman, lalu
> diuji di Docker Compose satu mesin. Bagian di bawah dibiarkan sebagai **latar belakang dan alasan**;
> status tiap komponen ada di tabel ini.

| Komponen | Pemilik | Sekarang di `stack.yaml` | Masih SPOF? | Yang masih butuh pemilik |
|---|---|---|---|---|
| gateway | Pison | satu per server **pool pison** (global), `/healthz` dan IP klien lewat berkas Swarm | Tidak, **bila** load balancer ada | adopsi `00-swarm.conf` ke `gateway/` (opsional) |
| Redis | Pison | **Redis Sentinel**: 1 master, 2 replika, 3 Sentinel, dipaku slot 1..3 pool pison. **Diuji di Compose**: master dimatikan, replika dipromosikan sekitar 6 detik, 0 galat | **Tidak** (belum diuji lintas server) | tidak ada |
| RabbitMQ | Pison | 3 node, dipaku, dnsrr | Tidak | perketat pembentukan klaster pertama |
| `auth-db` | Ifham | **InnoDB Cluster 3 node + 2 Router (VIP `auth-db-router`)**, skrip umum. **Diuji di Compose**: klaster, tulis lewat Router, failover Primary kurang dari 1 detik | **Tidak** (belum diuji lintas server) | `services/auth/src/Db.php`: ulangi koneksi sekali saat failover (error 2006, 2013, 1290); pisahkan `/sehat` dan `/siap` |
| `tts-db` | Ifham | **InnoDB Cluster 3 node + 2 Router** (pola sama, skema `job` dan `event_outbox` diterapkan di Primary). Pola diuji pada auth | **Tidak** (belum diuji) | worker sudah memakai lease, tidak ada perubahan wajib |
| `seaweedfs` | Ifham | 1 salinan, dipaku ke server berlabel `puisi.audio`. **Opsional `stack.efs.yaml`**: data di EFS, bisa pindah server | **Ya** (kurang dampaknya bila EFS) | Amazon S3 memerlukan `worker.py` memakai token sesi (kunci sandbox sementara) dan `gateway/rute/audio.conf` diarahkan ke S3 |
| `opensearch` | Evan | **3 node + HAProxy `opensearch:9200`**, penyetel replika (`number_of_replicas` 1). **Diuji di Compose**: node pemegang shard dimatikan, pencarian tetap menjawab 2 detik | **Tidak** (belum diuji lintas server) | `Indeks.php`: ubah `number_of_replicas` ke `1` agar penyetel tidak perlu |
| `search-consumer` | Evan | satu per server pool evan (global) | Tidak (usulan, perlu persetujuan) | konfirmasi aman banyak consumer |
| `analisis-emosi` | Ray | satu per server pool ray (global) | Tidak (usulan, perlu persetujuan) | konfirmasi aman banyak worker |
| `gambar-kutipan` (worker) | Ray | **tidak ada** | tidak tersambung sama sekali | langkah di bawah |
| gambar kutipan (**Lambda**) | Ridlo | `deploy/lambda/` + `CDN_URL` di image gateway | Bukan komponen server | putuskan: worker atau Lambda (jangan keduanya) |
| observability | Ray | **tidak ada** | Ya (hanya pemantauan) | adaptasi ke Swarm, atau terima |

**Batas yang tidak bisa dihilangkan dari sisi deploy:** tiga anggota per klaster hanya menahan **satu**
kegagalan; dua server mati di pool yang sama berarti klaster itu kehilangan mayoritas. Router MySQL mem-bootstrap dari
satu node.

---

## Pison (gateway, Redis, RabbitMQ)

### 1. Gateway

**Yang dilakukan `stack.yaml`:** satu gateway di **setiap** server (`mode: global`) dengan port 80 dibuka
langsung di server itu (`mode: host`). Load balancer menunjuk ke port 80 semua server. Image dibuat dari
`deploy/swarm/Dockerfile.gateway`, yang **menyalin** `gateway/nginx.conf`, `gateway/proxy-umum.conf`,
`gateway/rute/` dan `web/` (di Swarm tidak ada bind mount lintas server). Berkas Anda tidak diubah.

**Temuan 1, penting (diperiksa di laptop):** `gateway/nginx.conf` memakai
`limit_req_zone $binary_remote_addr zone=auth_login:10m rate=10r/m`. Di balik load balancer,
`$remote_addr` adalah IP load balancer, bukan IP pengguna. Akibatnya **semua pengguna berbagi satu
ember**: login ke-7 dalam semenit dari siapa pun mendapat 429. Di image Swarm saya menambah
`deploy/swarm/gateway/00-swarm.conf` yang memuat `real_ip_header X-Forwarded-For` dengan
`set_real_ip_from` untuk rentang privat dan `real_ip_recursive on`. Saya periksa dengan container
sungguhan: tanpa header, log mencatat IP proxy; dengan `X-Forwarded-For: 203.0.113.9` log mencatat
`203.0.113.9`; dengan `X-Forwarded-For: 1.2.3.4, 203.0.113.9` (klien memalsukan awalan) log tetap
mencatat `203.0.113.9`.

**Usulan:** pindahkan isi `00-swarm.conf` ke `gateway/` (misalnya `gateway/rute/00-umum.conf`) supaya
Compose dan Swarm memakai konfigurasi yang sama, lalu hapus `COPY ... 00-swarm.conf` dari
`Dockerfile.gateway`. Dua blok yang dipindahkan:

```nginx
location = /healthz { access_log off; default_type text/plain; return 200 "ok\n"; }
set_real_ip_from 10.0.0.0/8;  set_real_ip_from 172.16.0.0/12;  set_real_ip_from 192.168.0.0/16;
real_ip_header X-Forwarded-For;  real_ip_recursive on;
```

**Temuan 2:** `proxy_cache_path` dan `limit_req_zone` hidup **per replika**. Dengan tiga gateway, batas
login efektif bisa sampai 30 per menit per IP (tiga ember), dan cache API dihitung terpisah. Terima
sebagai batasan, atau pindahkan pembatasan laju ke ALB/WAF (belum diverifikasi tersedia).

**Temuan 3:** karena `web/` masuk ke image, mengubah frontend berarti membangun ulang image gateway dan
`docker service update --image`. Di Compose cukup menyimpan berkas.

**Belum diuji:** semuanya di AWS (gateway di tiga server, ALB, `/healthz` sebagai health check target).

### 2. Redis

**Pembaruan (revisi Hands On 3, S1):** usulan Redis Sentinel di bawah sudah dikerjakan. `stack.yaml` kini
menjalankan `redis-1..3` dan `redis-sentinel-1..3` (skrip start bersama `redis/mulai.sh`), dan `Cache.php` di
kedua layanan menemukan master lewat Sentinel lalu memeriksa `ROLE` (`src/MasterRedis.php`). Diuji di Compose
(`scripts/uji_ketahanan.py --tahap redis-failover,redis-mati,redis-stres`), belum di AWS. Bukti dan angka:
[`docs/AUDIT-SPOF-DAN-SKALABILITAS.md`](../../docs/AUDIT-SPOF-DAN-SKALABILITAS.md). Catatan lama di bawah dibiarkan
sebagai riwayat keputusan.

**Yang dilakukan `stack.yaml` (sebelum revisi):** satu salinan, **tidak dipaku**. Bila servernya mati, Swarm menjalankannya
lagi di server lain dengan cache kosong. Selama itu aplikasi turun ke database (di satu server,
skenario 4 `uji_anti_spof.py` LULUS). Ini **bukan** Redis HA.

**Mengapa tidak menambah Redis kedua ke `REDIS_HOSTS`** (dari membaca kode, belum diuji): `REDIS_HOSTS`
adalah daftar yang dicoba berurutan; dua Redis **tidak saling mereplikasi**. Proses yang panjang umur
(consumer, relay) menyimpan koneksi pertama yang berhasil (`Cache.php`, `self::$klien`). Bila Redis-1
sempat mati, consumer pindah ke Redis-2 dan **tetap di sana**, sedangkan setiap request web (proses
baru) kembali ke Redis-1 begitu hidup. Pembatalan cache memakai penghitung versi (`naikkanVersi()`
menjalankan `INCR`), jadi consumer menaikkan versi di Redis-2 sementara pembaca membaca versi lama di
Redis-1: hasil basi sampai TTL habis.

**Usulan, pilih salah satu:**
- **Terima** (disarankan untuk tugas ini): Redis hanya cache dan terbukti aplikasi tetap menjawab saat
  Redis mati. Tulis di laporan sebagai "komponen tunggal yang tidak menyebabkan henti layanan".
- **Redis Sentinel** (1 primary, 1 replika, 3 sentinel). Butuh perubahan `Cache.php` di dua layanan
  (`services/puisi` milik Ridlo dan `services/pencarian` milik Evan) agar bertanya ke Sentinel (phpredis
  punya kelas `RedisSentinel`). Pekerjaan kode di tiga pemilik, manfaatnya kecil.

### 3. RabbitMQ

**Yang dilakukan `stack.yaml`:** tiga node, masing-masing dipaku ke server berbeda, `endpoint_mode: dnsrr`
(supaya `rabbit@rabbitmq-N` menunjuk langsung ke task dan tidak lewat VIP Swarm yang memutus koneksi
AMQP menganggur), konfigurasi (`rabbitmq.conf`, `enabled_plugins`, `definitions.json`) lewat Swarm
`configs`. **Port management 15672 tidak dibuka ke luar.** Akibatnya `scripts/status_antrian.py`, yang
memakai `localhost:15672-15674`, tidak jalan dari laptop; saya menyediakan `skrip/cek.sh`.

**Risiko yang perlu Anda perhatikan** (dari membaca konfigurasi, belum diuji di AWS): `rabbitmq.conf` memakai
`classic_config`. Di Compose ketiga node start hampir bersamaan. Di Swarm, node 2 bisa start jauh lebih
dulu daripada node 1 (unduh image di server berbeda) dan bisa membentuk klaster sendiri. Jika itu
terjadi, ada tiga broker terpisah tanpa pesan error.

**Usulan:** tambahkan di `rabbitmq/rabbitmq.conf` waktu tunggu penemuan yang lebih lama, misalnya
`cluster_formation.discovery_retry_limit = 30` dan `cluster_formation.discovery_retry_interval = 2000`
(periksa nama opsinya pada dokumentasi RabbitMQ 4 sebelum dipakai). Sementara itu
Di AWS (23 November 2026) terbukti bahwa `docker service update --force` **tidak** memperbaikinya; yang berhasil: reset node 2 dan 3, `join_cluster`, `rabbitmq-queues grow` (`9server.sh rabbit`, lihat `docs/PANDUAN-DEPLOY-AWS.md` langkah 6).

Juga: `RABBITMQ_COOKIE` dibaca dari variabel lingkungan (bawaan `puisi-cookie-lokal`), dan sandi
`puisi/puisi` ada di `definitions.json`. Ganti keduanya bila sandbox dipakai bersama orang lain.

---

## Ifham (auth-db, tts-db, seaweedfs)

> **Status:** `auth-db` dan `tts-db` **sudah dibuat menjadi klaster** di `stack.yaml` (skrip umum
> `skrip/init-innodb-cluster.sh`, `mysql/klaster.cnf`), diuji di Compose. Yang tertulis di bawah adalah
> alasan rancangannya. `seaweedfs` masih tunggal (lihat bagian 3).

**Keadaan sekarang di `stack.yaml`:** ketiganya satu salinan dan **dipaku ke satu server** (`auth-db` slot 1,
`tts-db` dan `seaweedfs` slot 2). Pemakuan disengaja: tanpa itu Swarm bisa menjadwalkannya ke server
lain dengan volume **kosong**, dan data tampak hilang. Bila servernya mati, fiturnya berhenti sampai
server itu hidup lagi.

### 1. auth-db (paling penting: login dan daftar)

**Dampak bila mati** (dari kontrak dan audit): daftar dan login gagal. Token yang sudah terbit (berlaku
1 jam) tetap bisa dipakai mengirim puisi karena poem-service memeriksa token sendiri.

**Usulan utama: InnoDB Cluster 3 node mengikuti pola poem-db.**

| Bagian | Yang dibutuhkan |
|---|---|
| Node | `auth-db-1..3`, dipaku slot 1..3, `hostname`, `endpoint_mode: dnsrr`, volume per node, `start_period` besar |
| Pembentuk klaster | job `auth-db-cluster-init` (`mode: replicated-job`), meniru `poem-db-cluster-init` |
| Titik masuk | 2 router (`auth-db-router-1/2`) atau satu layanan router 2 replika. `auth-service` hanya menerima **satu** `DB_HOST`, jadi arahkan ke nama router dan `DB_PORT=6446` |
| `init.sql` | meniru `services/puisi/db/init.sql`: `SET sql_log_bin = 0` di awal supaya pembuatan pengguna dan skema tidak menjadi transaksi yang berbeda antar node (kemungkinan besar alasannya; periksa), pengguna `auth`, hak replikasi |
| `init-cluster.sh` | skrip poem (`services/puisi/db/init-cluster.sh`, milik Ridlo) menulis tetap `poem-db-1..3`, `poem_db`, `puisi_cluster`. Perlu disalin atau diparameterkan (`NODES`, nama klaster, skema) |

Perubahan kode di `services/auth/src/Db.php` (membaca `DB_HOST`/`DB_PORT` dari lingkungan sudah ada): ulangi
sekali bila koneksi putus atau tulis ditolak saat failover (error `2006`, `2013`, `1290`). Tanpa itu,
beberapa request pertama saat Primary pindah akan 500.

**Healthcheck:** `/sehat` di `services/auth/public/index.php` menjalankan `SELECT 1` ke database
(diperiksa). Compose hanya menandai container "unhealthy", tetapi **Swarm membunuh task yang tidak
sehat**. Saat Primary pindah, semua replika `auth-service` bisa gagal bersamaan dan dimatikan bersamaan,
memperpanjang henti layanan. Usulan: pisahkan `/sehat` (proses hidup, tanpa database) dari `/siap`
(database terjangkau), dan pakai `/sehat` sebagai healthcheck container. Sementara itu `stack.yaml`
menaikkan `retries` menjadi 12. (`poem-service` tidak punya masalah ini: `/sehat`-nya tidak menyentuh database.)

Periksa bahwa **setiap tabel memiliki primary key** (syarat Group Replication). Pada `users` ada
(`id`). Biaya memori: tiga node MySQL poem terukur sekitar 2,6 GiB; auth-db akan serupa.

**Cara tahu berhasil:** matikan server pemegang Primary `auth-db`; login pulih kurang dari 60 detik
dan akun yang dibuat sebelumnya tetap bisa masuk.

**Alternatif:** (b) replika asinkron dengan promosi manual: murah, tetapi **bukan** otomatis sehingga
tidak boleh diklaim bebas SPOF. (c) RDS Multi-AZ: draf lama menduga diblokir sandbox dan belum
diverifikasi.

### 2. tts-db

Dampaknya terbatas pada fitur audio ("fitur lain jalan", audit). Pola penyelesaiannya sama dengan `auth-db`.
Tabel `job` dan `event_outbox` punya primary key (diperiksa). Worker sudah memakai lease dan
`lease_token`, jadi aman bila banyak worker berjalan.

**Pilihan hemat:** audio turunan dan dapat dibuat ulang dari event `puisi.dibuat`. Bila kelompok memilih
tidak mengklasterkan `tts-db`, **terimalah sebagai SPOF yang didokumentasikan** untuk fitur audio dan
tulis langkah pemulihannya. Itu lebih jujur daripada klaster setengah jadi.

### 3. seaweedfs

Satu proses `weed server -s3` (master, volume, filer, dan S3 jadi satu) dengan data di `/data` satu server.

| Pilihan | Catatan |
|---|---|
| **Amazon S3** | `S3_ENDPOINT`, kunci, dan bucket di worker sudah dari lingkungan. Gateway `rute/audio.conf` (milik Pison) harus meneruskan `/audio/` ke S3. **Belum diverifikasi**: S3 tersedia di sandbox, dan kunci IAM bisa dibuat. Paling sederhana bila ada |
| **SeaweedFS klaster** | beberapa master (raft), minimal 2 volume server dengan replikasi antar server (`-defaultReplication`), dan penyimpanan metadata filer yang bersama (bawaan menyimpan lokal). Rancangan kasar, **belum saya verifikasi**; baca dokumentasi SeaweedFS sebelum memutuskan. Kompleks |
| **Terima** | audio dapat dibuat ulang (lihat di atas). Dokumentasikan |

Catatan: `tts-audio-init` (job pembuat bucket) dan `text-to-speech` ×2 sudah ada di `stack.yaml`. Image TTS
mengunduh model suara saat build, jadi bangun di server (bukan laptop).

---

## Evan (opensearch, search-consumer)

> **Status:** OpenSearch **sudah 3 node** di `stack.yaml` dengan HAProxy sebagai satu alamat
> (`opensearch:9200`), dan layanan `opensearch-replika` menyetel `number_of_replicas` ke 1 **tanpa mengubah
> kode Evan**. Diuji di Compose. Perubahan di `Indeks.php` tetap disarankan (lebih bersih), tetapi tidak wajib.

> **Temuan dari AWS (23 November 2026):** healthcheck `/_cluster/health` pada node OpenSearch membuat klaster **tidak pernah terbentuk di Swarm** (Swarm baru mendaftarkan nama DNS task yang sehat, sehingga node saling tidak
> menemukan). Sudah diperbaiki di `stack.yaml` (healthcheck `GET /` saja; HAProxy tetap memeriksa klaster), tanpa mengubah kode Evan. Setelahnya klaster hijau 3 node dan `uji_e2e.py` tahap `pencarian` lulus.
> Detail: `docs/LAPORAN-EKSPERIMEN-AWS.md` bagian 5.

### 1. OpenSearch: tiga node **dan** satu perubahan kode wajib

**Keadaan sekarang:** satu node (`discovery.type: single-node`), dipaku slot 3.

**Masalah yang tidak terlihat dari konfigurasi saja** (diperiksa di kode):
`services/pencarian/src/Indeks.php` baris 14 menulis `'number_of_replicas' => 0`
dengan komentar "satu node, replika tidak akan pernah ditempatkan". Bila OpenSearch dijadikan tiga node
tetapi nilai ini **tidak diubah**, setiap shard hanya punya satu salinan dan **hilang bersama node-nya**:
tiga server tidak melindungi apa pun. Jadi perubahan yang dibutuhkan ada dua:

1. **Kode:** ubah `number_of_replicas` menjadi `1` (dua salinan tiap shard, tahan kehilangan satu node).
   Untuk indeks `puisi` yang sudah ada (`Konfig::INDEKS`), `Indeks::pastikan` tidak membuat ulang, jadi
   ubah lewat API: `PUT /puisi/_settings` dengan `{"index":{"number_of_replicas":1}}`.
2. **Konfigurasi (di `stack.yaml`, bisa saya kerjakan setelah Anda setuju):**

   ```yaml
   opensearch-1:                  # juga -2, -3, dipaku slot 1..3, hostname sama, endpoint_mode: dnsrr
     environment:
       cluster.name: puisi-cari
       node.name: opensearch-1
       discovery.seed_hosts: opensearch-1,opensearch-2,opensearch-3
       cluster.initial_cluster_manager_nodes: opensearch-1,opensearch-2,opensearch-3
       # hapus discovery.type: single-node
   ```

   Volume per node, `vm.max_map_count` di host (sudah ditangani `skrip/siapkan-node.sh`), `ulimits` seperti
   sekarang. Memori sekitar tiga kali (heap 512 MB ditambah overhead), **belum diukur**.

**Klien:** `OPENSEARCH_URL` hanya satu alamat. Dengan `dnsrr` nama itu menunjuk ke tiga IP, dan klien
memakai yang pertama; bila node itu mati, permintaan gagal sampai DNS diperbarui. Usulan: terima daftar
`OPENSEARCH_URLS` dengan urutan coba seperti `AMQP_URLS` (di `OpenSearch.php`).

**Cara tahu berhasil:** `GET /_cluster/health` hijau dengan tiga node; matikan server pemegang satu node:
status kuning, `GET /api/search?q=...` tetap 200 dengan hasil sama; server hidup lagi: hijau.

### 2. search-consumer ×2

Di Compose hanya 1; `stack.yaml` menjalankan **2** (usulan, butuh persetujuan Anda). Dasarnya dari
membaca kode: `Penangan.php` menulis lewat `_update` dengan `doc_as_upsert` dan komentarnya
menyatakan urutan event tidak dijamin, jadi dua consumer yang berebut antrean aman secara desain. Yang
perlu Anda pastikan: tidak ada keadaan bersama lain yang mengandalkan satu consumer (versi cache memakai
`INCR`, atomik). **Cara uji:**
`python scripts/kirim_event.py puisi.dibuat contoh/... --ulang 30` lalu bandingkan isi indeks dengan satu consumer.
Bila Anda tidak setuju, ubah `replicas: 2` menjadi `1` di `stack.yaml`.

### 3. Urutan start search-service

`bin/siapkan_indeks.php` menunggu OpenSearch maksimal 2 menit lalu menyerah dan **tetap menjalankan
service**. Tanpa `depends_on` di Swarm, ini bisa terjadi bila OpenSearch lambat: indeks tidak dibuat. Usulan:
panggil `Indeks::pastikan` secara malas pada request pertama bila indeks belum ada. Sementara itu:
`docker service update --force puisi_search-service`.

---

## Ray (analisis-emosi, gambar-kutipan, observability)

### 1. analisis-emosi ×2

Di Compose hanya 1; `stack.yaml` menjalankan **2** (usulan, butuh persetujuan Anda). Dari kontrak:
worker membaca antrean `q.analisis-emosi`, hasilnya disimpan poem-service per `sumber` secara upsert, dan
consumer wajib idempoten, jadi dua worker aman secara desain. **Pastikan** worker tidak menyimpan keadaan
lokal, lalu uji dengan mengirim satu event dua kali (`--event-id` sama) dan memeriksa hasilnya sama.
Bila tidak setuju: `replicas: 1`.

### 2. gambar-kutipan: belum tersambung ke mana pun

Kodenya ada di `workers/gambar-kutipan/` (Node 20 dan Jimp), tetapi **tidak ada layanan Compose-nya
dan tidak ada antrean `q.gambar-kutipan` di `rabbitmq/definitions.json`** (diperiksa). Tidak ada yang
mengonsumsi, jadi dokumen rancangan yang menulis "setiap worker berjalan 2 replika" tidak benar
untuk worker ini. Yang dibutuhkan, **berurutan** karena lintas pemilik:

| # | Pekerjaan | Pemilik berkas |
|---|---|---|
| 1 | Antrean dan binding di `rabbitmq/definitions.json`. Salin pola `q.analisis-emosi` dan `.dlq`-nya: quorum, `x-delivery-limit: 3`, dead letter exchange `puisi.dlx`, binding `puisi.events` dengan routing key `puisi.dibuat`, dan binding DLQ pada `puisi.dlx` | **Pison** |
| 2 | Bucket dan kunci S3 untuk gambar. Worker **mengunggah ke S3**, jadi bergantung pada penyimpanan Ifham (SeaweedFS). Perlu bucket terpisah (mis. `kutipan`) dan kunci di `secrets/seaweedfs_s3.json`; rute `gateway/rute/audio.conf` hanya membuka bucket audio, jadi pembacaan gambar perlu rute sendiri | **Ifham** dan **Pison** |
| 3 | Fragmen `compose/gambar-kutipan.yaml` (profil `kutipan` dan `semua`, 2 replika) dan `include` di `compose.yaml` | **Ray** |
| 4 | Putuskan bersama kelompok: gambar kutipan lewat worker ini, atau lewat Lambda dan CloudFront (Hands-on 1, folder `lambda/`). Jangan keduanya menghasilkan `file_gambar` | semua |
| 5 | Setelah 1 sampai 3 ada, saya menambah layanan ini ke `stack.yaml` (2 replika, `max_replicas_per_node: 1`) dan ke `skrip/bangun-image.sh` | Ridlo |

**Cara tahu berhasil:** `python scripts/status_antrian.py` menampilkan `q.gambar-kutipan` dengan 2 consumer.

### 3. Observability: tidak ada di `stack.yaml`

Prometheus, Grafana, Loki, Promtail, cAdvisor, Alertmanager, Blackbox, dan exporter **tidak dimasukkan**
karena rancangannya mengandalkan hal yang tidak ada di Swarm: `docker.sock` untuk menemukan container
**lokal**, bind mount dari `observability/` dan `/var/lib/docker`, dan `container_name`. Bila ingin
dipasang di Swarm:

- Prometheus memakai `dockerswarm_sd_configs` (role `tasks`) lewat `docker.sock` milik **manajer**
  (dipaku `node.role == manager`). Label `metrics.scrape` dan `metrics.port` sudah saya pasang pada
  `deploy.labels` setiap layanan di `stack.yaml`, tersedia sebagai `__meta_dockerswarm_service_label_*`.
- Promtail, cAdvisor, dan node exporter dijalankan `mode: global` (satu per server).
- Konfigurasi lewat Swarm `configs` (bukan bind mount).
- Prometheus, Grafana, dan Loki masing-masing satu salinan dengan volume lokal, jadi **tetap SPOF untuk
  pemantauan** (pengguna tidak terdampak). Putuskan: terima, atau jalankan dua Prometheus.

---

## Ridlo (pemilik `deploy/swarm/`)

> Tambahan 23 November 2026: **Lambda** (`deploy/lambda/`), **dua jenis server** (data dan aplikasi),
> **`stack.efs.yaml`**, dan draf lama dihapus. Catatan di bawah masih berlaku.

Hal yang saya ketahui belum sempurna dan perlu keputusan Anda:

- **Router MySQL** mem-bootstrap dari **satu** node (`MYSQL_HOST`). Router dipaku ke server yang sama dengan
  node asalnya. Bila router di-restart saat node asalnya mati, ia gagal terus sampai node itu hidup. Router
  lainnya tetap melayani.
- **`init-cluster.sh` di Swarm** berjalan sebagai job tanpa batas percobaan (`on-failure`). Bila klaster
  rusak berat, job mengulang tanpa henti; hentikan dengan `docker service rm puisi_poem-db-cluster-init`.
- **Kata sandi bawaan** (`poem/poem`, `puisi/puisi`) ada di `stack.yaml` karena identik dengan Compose.
  Tidak ada port database atau RabbitMQ yang dibuka ke luar, tetapi ganti sebelum dipakai di luar sandbox.
- **Kapasitas** terukur di AWS dengan 38 layanan (`docs/LAPORAN-EKSPERIMEN-AWS.md` bagian 3.2): server 7 sampai 9 paling ketat (tersedia 267 sampai 426 MB dari 1909 MB), dan hanya diukur diam, bukan di bawah beban.
- **Tiga server hanya menahan satu kegagalan.** Dua server mati berarti Swarm, MySQL, dan RabbitMQ semuanya
  kehilangan mayoritas.
