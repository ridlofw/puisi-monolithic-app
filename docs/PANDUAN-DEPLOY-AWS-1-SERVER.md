# Panduan Deploy ke AWS Sandbox: versi Single (1 server)

**Untuk siapa:** anggota tim yang ingin menjalankan **seluruh fitur** aplikasi puisi di **satu** server EC2 sebagai pembanding versi
Scalable 9 server ([`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md)). Ditulis untuk pemula: ikuti langkahnya berurutan, salin perintahnya apa adanya.

**Bagaimana dokumen ini dibuat:** setiap langkah dijalankan sungguhan di sandbox pada **28 November 2026**. Angka di dokumen ini adalah angka
yang tampil di layar saat itu. Bagian **10 (Status bukti)** memisahkan yang sudah dijalankan dari yang belum.

---

## 0. Apa yang dimaksud "Single"?

Analogi: versi Scalable seperti restoran dengan 9 dapur, dan setiap juru masak penting punya cadangan. Versi Single adalah **satu dapur, satu orang
per tugas**. Semua menu (fitur) tetap tersedia, tetapi bila satu orang sakit, menu itu berhenti; bila dapurnya tutup, semuanya berhenti.

```
Browser --HTTPS--> CloudFront (satu alamat: https://dxxxx.cloudfront.net)
                     |-- /  /js/*  style.css  latar*.jpeg --> S3        (halaman; di-cache CloudFront)
                     |-- /fungsi*                        --> Lambda     (gambar kutipan, Hands-on 1)
                     |-- /api/*  /audio/*                --> SATU server EC2 (port 80, hanya dari CloudFront)
                                                              gateway -> semua layanan, masing-masing 1 container
```

| Komponen | Scalable (9 server) | **Single (1 server)** |
|---|---|---|
| Server EC2 | 9 `t3.small` di 3 zona | **1 `t3.small`** (2 GiB RAM, 2 vCPU) di zona `us-east-1a` |
| Pengatur container | Docker Swarm | **Docker Compose** ([`deploy/aws/1server/compose.yaml`](../deploy/aws/1server/compose.yaml)) |
| Gateway | 3 (satu per server infra) di belakang ALB | **1**, tanpa ALB |
| RabbitMQ | 3 node, quorum queue 3 anggota | **1 node** |
| Redis | 3 node + 3 Sentinel | **1 node** |
| poem-db, auth-db, tts-db | masing-masing klaster MySQL 3 node + router | **masing-masing 1 MySQL** |
| OpenSearch | 3 node + HAProxy | **1 node** |
| poem-service, relay, consumer, auth-service, search-service | 2 atau 3 replika | **1 masing-masing** |
| worker tag, genre, emosi, suara; search-consumer | 1 sampai 3 | **1 masing-masing** |
| Lambda + S3 + CloudFront | ada | **ada** (skrip yang sama) |
| Observability (Prometheus, Grafana, Loki) | tidak dipasang di AWS | **tidak dipasang** |

Jumlahnya: **18 container** yang terus berjalan, ditambah `tts-audio-init` yang hanya jalan sekali.

Yang **sama** dengan Scalable supaya perbandingannya adil: kode aplikasi (tidak diubah sama sekali; alamat database, Redis, dan RabbitMQ hanya
diberikan lewat variabel lingkungan berisi satu host), setelan memori (MySQL `innodb_buffer_pool_size=64M`, heap OpenSearch 384 MB), image gateway
versi AWS (`deploy/swarm/Dockerfile.gateway`), dan CloudFront dua jalur.

---

## 1. Aturan sandbox yang membentuk rancangan ini

| Aturan (dicek 28 Nov 2026) | Akibat |
|---|---|
| Tipe instance: `t3.small` dan `t2.small` **diizinkan**; `t3.medium`, `t2.medium`, `t3a.medium`, `t3.large`, `m5.large`, `c5.large` **ditolak** (`UnauthorizedOperation`, dicek dengan `run-instances --dry-run`) | Server terbesar yang boleh: **2 GiB RAM**. Single memakai `t3.small` |
| Sesi lab sekitar 3 jam, sesudah itu semua sumber daya dihapus | Deploy diulang dari nol tiap sesi; skrip membuatnya bisa diulang |
| AMI harus milik Amazon; tidak bisa membuat IAM role | Amazon Linux 2023; `LabInstanceProfile` untuk SSM, `LabRole` untuk Lambda |

**Keterbatasan utama:** aplikasi lengkap butuh lebih dari 2 GiB. Di laptop, 18 container memakai sekitar **3161 MiB**
([bukti](bukti-1server/laptop-single-ram.txt)). Di `t3.small` sisanya disimpan di **swap** (memori cadangan di disk, jauh lebih lambat dari RAM).
Server diberi swap **4 GiB** (versi 9 server: 3 GiB). Akibatnya Single **berjalan dan lulus uji**, tetapi lebih lambat saat data harus dibaca
kembali dari swap. Catat ini setiap kali membandingkan angka Single dengan Scalable.

---

## 2. Yang harus disiapkan

- Lab AWS Academy **aktif** (Start Lab, lampu AWS hijau), lalu console dan **CloudShell** terbuka (ikon `>_` di bilah atas, region **N. Virginia**).
- Tidak perlu apa pun di laptop: kode diambil langsung dari **GitHub**, baik oleh CloudShell maupun oleh server.
- Waktu: sekitar **30 menit** dari nol sampai alamat HTTPS jalan (kebanyakan menunggu).
- **Privasi:** skrip menyaring nomor akun dan email dari keluarannya. Tetap jangan menempel nomor akun, email, atau kunci ke chat, GitHub,
  atau tangkapan layar. Bilah atas console memuat nomor akun: potong sebelum membagikan gambar.

Semua catatan skrip disimpan di `~/puisi1` di CloudShell (versi 9 server memakai `~/puisi9`; keduanya tidak saling mengganggu).

**Resource AWS yang dibuat (semuanya satu):** 1 server EC2, 1 Security Group, 1 bucket S3 (halaman web dan gambar latar), 1 fungsi Lambda,
1 distribusi CloudFront. (Versi 9 server membuat 2 distribusi dan 2 bucket: distribusi gambar dari skrip Hands-on 1 dan bucket kode sementara.
Di Single keduanya tidak dibutuhkan, jadi tidak dibuat.)

---

## 3. Langkah 1: ambil kode dari GitHub di CloudShell

```bash
git clone --depth 1 -b ridlo/single-1server https://github.com/ridlofw/puisi-monolithic-app.git ~/puisi1/kode
cp ~/puisi1/kode/deploy/aws/1server.sh ~/1server.sh
```

Ganti `ridlo/single-1server` dengan `main` setelah cabang itu digabung ke `main`. Bila `~/puisi1/kode` sudah ada dari sesi sebelumnya,
hapus dulu (`rm -rf ~/puisi1/kode`) atau perbarui (`git -C ~/puisi1/kode pull`). Server mengambil **cabang yang sama** di langkah 5.

Rahasia (sandi database, kunci JWT) **tidak ada di GitHub**: dibuat baru di server pada langkah 5.

---

## 4. Langkah-langkah deploy

Semua dijalankan di CloudShell dari `~`. Setiap perintah **aman diulang**. Kolom "Waktu" adalah waktu terukur di AWS.
Tambahkan `| tee ~/puisi1/log-<nama>.txt` di belakang perintah bila ingin menyimpan log (CloudShell kadang lambat menampilkan keluaran).

| # | Perintah | Yang terjadi | Waktu | Tanda berhasil |
|---|---|---|---|---|
| 2 | `bash ~/1server.sh luncurkan` | Membuat Security Group `puisi-1server-sg` **tanpa port terbuka**, lalu **1 `t3.small`** Amazon Linux 2023, disk 30 GiB. User-data memasang Docker, Docker Compose v2.29.7, buildx v0.17.1, git, swap 4 GiB, `vm.max_map_count=262144` (syarat OpenSearch) | < 1 menit | baris `puisi-single  t3.small  us-east-1a  running  ec2-...` dan `kredit CPU: unlimited` |
| 3 | `cd ~/puisi1/kode && STATE_FILE=~/puisi1/gambar.state LATAR_DIR=~/latar TANPA_CLOUDFRONT=1 bash deploy/lambda/siapkan-gambar.sh; cd ~` | **Gambar kutipan (Hands-on 1):** bucket S3 publik, fungsi Lambda `puisi-gambar` + Function URL, gambar latar, kebijakan cache. `TANPA_CLOUDFRONT=1`: distribusi CloudFront dibuat nanti, sekali saja (langkah 10). `LATAR_DIR` adalah folder berisi `latar1.jpeg` dst. dari dosen; bila tidak ada, skrip membuat gambar pengganti | sekitar 1 menit | `[OK] 200 image/jpeg` pada uji Lambda dan `TANPA_CLOUDFRONT=1: distribusi CloudFront gambar TIDAK dibuat` |
| 4 | `bash ~/1server.sh tunggu` | Menunggu server terdaftar di SSM (kendali tanpa SSH) dan user-data selesai | 1 sampai 3 menit | versi Docker, Compose, buildx, git; `RAM total 1909 MB`, `swap 4095 MB`, `262144` |
| 5 | `bash ~/1server.sh kode` | Server **mengambil kode langsung dari GitHub** (`git clone`, cabang yang sama dengan langkah 1) ke `/opt/puisi`, **membuat rahasia baru** (`scripts/siapkan_rahasia*.py`) dan memberi izin baca 644 | < 1 menit | `commit di CloudShell` dan `commit di server` sama, lalu `compose.yaml`, `rabbitmq.conf` |
| 6 | `bash ~/1server.sh bangun` | Membangun 8 image di server, di latar belakang. Image gateway disisipi rentang IP CloudFront | sekitar 3 menit | ulangi `bash ~/1server.sh status` sampai muncul `KELUAR=0` dan `SELESAI`, serta 8 baris image `...:single` |
| 7 | `bash ~/1server.sh naik` | `docker compose up -d` semua layanan | 3 sampai 6 menit | tabel layanan: semua `Up`. **Bila ada yang belum (`dependency failed to start`), tunggu 1 menit lalu jalankan `naik` lagi** (lihat bagian 8) |
| 8 | `bash ~/1server.sh verifikasi` | Daftar container, `/healthz`, memori, lalu `scripts/uji_e2e.py` **dari dalam server** | sekitar 1 menit | `-- 10 dari 10 tahap LULUS` |
| 9 | `bash ~/1server.sh buka` | Membuka port 80 **hanya untuk CloudFront** (daftar alamat resmi AWS `com.amazonaws.global.cloudfront.origin-facing`), bukan untuk seluruh internet | detik | `port 80 diizinkan hanya dari CloudFront (pl-...)` |
| 10 | `bash ~/1server.sh cloudfront` | **Satu-satunya** distribusi CloudFront, **dua jalur** (skrip versi 9 server, asalnya diganti server tunggal): halaman dari S3, `/fungsi` ke Lambda, `/api` dan `/audio` ke server | 5 sampai 15 menit | `uji lulus: 8 dari 8` dan `ALAMAT APLIKASI (HTTPS): https://dxxxx.cloudfront.net/` |
| 11 | `cd ~/puisi1/kode && GATEWAY=https://dxxxx.cloudfront.net python3 scripts/uji_e2e.py --tunggu 240; cd ~` | Uji ujung ke ujung lewat alamat HTTPS publik | sekitar 1 menit | `-- 10 dari 10 tahap LULUS` |

Alamat gambar kutipan untuk frontend: distribusi di langkah 10 menyisipkan alamatnya sendiri ke `api.js` yang diunggah ke S3, sehingga halaman,
API, dan gambar memakai satu alamat yang sama.

---

## 5. Mencoba aplikasi

1. Buka alamat dari langkah 10 (`https://dxxxx.cloudfront.net/`). Halaman Login dan Register muncul.
2. **Register** satu akun, lalu **Login**. Kirim satu puisi.
3. Tunggu sekitar 30 detik, muat ulang galeri. Kartu puisi memuat tag, genre, emosi, dan pemutar audio.
4. Kotak pencarian menemukan puisi yang baru dikirim. Tombol gambar kutipan membuat gambar lewat Lambda.

---

## 6. Memantau

| Perintah | Menunjukkan |
|---|---|
| `bash ~/1server.sh memori` | RAM terpakai dan tersedia, swap, beban, `vmstat` (si/so = data keluar-masuk swap per detik), memori dan CPU tiap container |
| `bash ~/1server.sh verifikasi` | semua pemeriksaan di langkah 8 |
| `bash ~/1server.sh jalankan '<perintah>'` | perintah apa pun di server, misalnya `'cd /opt/puisi && docker compose -f deploy/aws/1server/compose.yaml --project-directory . logs --tail 20 poem-service'` |

**Tentang observability (Grafana dan kawan-kawan):** tidak dipasang di Single, sama seperti di versi 9 server. AWS sudah mencatat metrik dasar setiap
instance EC2 di **CloudWatch** tanpa memasang apa pun: CPU, jaringan, dan baca-tulis disk, setiap 5 menit (Console: EC2 -> pilih instance -> tab
Monitoring; langkah lengkap dan cara membacanya: [`PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md`](PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md)). Memori dan metrik per container **tidak** termasuk; untuk itu dipakai `bash ~/1server.sh memori`. Memasang Prometheus, Grafana, dan Loki
di server 2 GiB yang sudah memakai swap akan memperlambat aplikasi yang sedang diukur.

---

## 7. Membersihkan (sesudah selesai)

Urutan dari yang paling luar. Sumber daya juga hilang sendiri saat sesi lab berakhir, tetapi menghapusnya lebih dulu menghemat anggaran.

```bash
cd ~/puisi1/kode
W_DIR=~/puisi1 YA=1 bash deploy/aws/cloudfront-dua-jalur.sh hapus                 # distribusi CloudFront (5 sampai 15 menit, tanpa keluaran sampai selesai)
STATE_FILE=~/puisi1/gambar.state YA=1 bash deploy/lambda/siapkan-gambar.sh hapus   # Lambda, kebijakan cache, bucket S3 beserta isinya
cd ~ && YA=1 bash ~/1server.sh hapus                                               # server dan Security Group
```

---

## 8. Pemecahan masalah (semuanya terjadi saat uji 28 Nov)

| Gejala | Penyebab | Solusi |
|---|---|---|
| `naik` berakhir dengan `dependency failed to start: container puisi-single-seaweedfs-1 is unhealthy`; `seaweedfs` `Restarting (255)`; log: `open /run/secrets/seaweed_s3_config: permission denied` | Berkas rahasia dibuat dengan izin 600 milik root; SeaweedFS di dalam container berjalan sebagai pengguna biasa. Compose (bukan Swarm) memasang berkas rahasia apa adanya. Di laptop Windows izin ini tidak berlaku, jadi tidak terlihat | Sudah diperbaiki di `1server.sh kode` (`chmod 644 secrets/*`). Untuk server yang terlanjur: `bash ~/1server.sh jalankan 'chmod 644 /opt/puisi/secrets/*'` lalu `naik` |
| `naik` berakhir dengan `dependency failed to start` walaupun log layanan itu normal; `auth-service` sempat `unhealthy` (log: `GET /sehat 503` lalu `200`) | Start lambat karena swap: pemeriksaan kesehatan habis kesempatan sebelum layanan siap | Tunggu sekitar 1 menit, jalankan `bash ~/1server.sh naik` lagi. Layanan yang sudah jalan tidak diganggu |
| Keluaran memuat `.../puisi1/<sesi>` (putaran pertama) | Penyaring privasi menganggap potongan `cloudshell-user/puisi1/kode` sebagai nama sesi | Hanya tampilan; penyaring di `1server.sh` sudah diperbaiki |
| CloudShell: "Sesi Anda telah berakhir" | Diam terlalu lama | Klik **Hubungkan kembali**; berkas di `~` tetap ada |

---

## 9. Batasan yang diketahui

- **Setiap container adalah titik gagal tunggal (SPOF)**, dan server itu sendiri juga. Ini disengaja: itulah arti Single.
- **Memori tidak cukup tanpa swap.** Sesudah uji ujung ke ujung dari dalam server: RAM tersedia 286 dari 1909 MB, swap terpakai 1634 MB, dan
  selama uji data dibaca kembali dari swap sampai 6352 KB per detik. Sesudah uji lewat HTTPS: tersedia 276 MB, swap 1752 MB. OpenSearch saja
  memegang sekitar 760 MiB RAM (heapnya dikunci di RAM). Angka kinerja Single dipengaruhi swap; tuliskan itu saat membandingkan dengan Scalable.
- **CPU menganggur sudah sekitar 21%.** Menurut CloudWatch, rata-rata CPU per 5 menit saat aplikasi berjalan tanpa pengguna adalah 21,0% dan 20,7%
  (puncak build 100%). `t3.small` hanya dijamin 20% (batas dasar); di atas itu server memakai "kredit CPU". Mode kredit server ini `unlimited`
  (bawaan): CPU tidak diperlambat, tetapi pemakaian di atas 20% dalam waktu lama ditagih sedikit. Versi 9 server memakai tipe dan mode yang sama,
  tetapi bebannya terbagi ke 9 server.
- Uji beban dan stress test **belum** dijalankan di Single (keputusan tempat uji belum diambil tim).

---

## 10. Status bukti

Dijalankan dua putaran pada 28 Nov 2026. **Putaran 2 adalah dokumen ini apa adanya**: semua resource putaran 1 dihapus (bagian 7), lalu
langkah 1 sampai 11 dijalankan dari nol dengan kode dari GitHub (cabang `ridlo/single-1server`, commit `21054f6`).

| Langkah | Putaran 2: dari nol lewat GitHub (dokumen ini) | Putaran 1: kode dari laptop (versi lama skrip) |
|---|---|---|
| Cek tipe instance (`--dry-run`) | | **Dijalankan**: hanya `t3.small`, `t2.small` |
| Compose Single di laptop | | **10 dari 10**, 18 container sekitar 3161 MiB |
| 1 git clone di CloudShell | **Dijalankan** persis seperti tertulis | (arsip `.tgz` dari laptop) |
| 2 luncurkan | **Dijalankan** | Dijalankan |
| 3 siapkan-gambar `TANPA_CLOUDFRONT=1` | **Dijalankan**: bucket, Lambda (uji langsung lulus), tanpa distribusi gambar | (versi lama: membuat distribusi gambar juga, 2 dari 2) |
| 4 tunggu | **Dijalankan** (termasuk `git version 2.50.1`) | Dijalankan |
| 5 kode (server `git clone`) | **Dijalankan**: commit di server sama dengan di CloudShell (`21054f6`) | (arsip lewat bucket S3) |
| 6 bangun | **Dijalankan**: 8 image, 3 menit 21 detik, `KELUAR=0` | 3 menit 3 detik |
| 7 naik | **Dijalankan sekali, semua `Up`** (perbaikan izin rahasia terbukti) | butuh `chmod` manual dan dua kali `naik` ulang |
| 8 verifikasi | **`uji_e2e.py` 10 dari 10** dari dalam server | 10 dari 10 |
| 9 buka | **Dijalankan** | Dijalankan |
| 10 cloudfront | **Uji 8 dari 8**, satu-satunya distribusi | 8 dari 8 |
| 11 uji HTTPS | **`uji_e2e.py` 10 dari 10** lewat `https://d1wkw4tk9hk1ny.cloudfront.net` | 10 dari 10 |
| Jumlah resource sesudah deploy | **1 server, 1 bucket, 1 Lambda, 1 CloudFront** | 1 server, 2 bucket, 1 Lambda, 2 CloudFront |
| Bagian 7 (membersihkan) | belum (resource putaran 2 masih menyala saat dokumen ini ditulis) | **Dijalankan** (tiga perintah apa adanya); pemeriksaan sesudahnya: 0 server, 0 Security Group, 0 bucket, 0 Lambda, 0 CloudFront |
| Halaman aplikasi di browser | | Halaman Login dan Register tampil lewat HTTPS ([tangkapan](bukti-1server/aplikasi-lewat-https-cloudfront.jpg)) |
| CloudWatch (metrik EC2 bawaan) | | **Dibaca**: CPU, jaringan, disk, kredit CPU; memori tidak. Cara membaca: [`PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md`](PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md) |

Catatan kecil: kebijakan cache CloudFront buatan `cloudfront-dua-jalur.sh` (`puisi-StatisPendek`) tidak ikut dihapus oleh bagian 7. Kebijakan
cache tidak berbiaya dan dipakai ulang pada deploy berikutnya.

Bukti (log tanpa nomor akun dan email): [`docs/bukti-1server/`](bukti-1server/).

---

## 11. Peta berkas

| Berkas | Fungsi |
|---|---|
| [`deploy/aws/1server.sh`](../deploy/aws/1server.sh) | Pengendali Single: `luncurkan`, `tunggu`, `kode`, `bangun`, `status`, `naik`, `verifikasi`, `memori`, `buka`, `cloudfront`, `jalankan`, `hapus` |
| [`deploy/aws/1server/compose.yaml`](../deploy/aws/1server/compose.yaml) | Definisi 18 layanan Single (setiap komponen satu) |
| [`deploy/aws/1server/rabbitmq.conf`](../deploy/aws/1server/rabbitmq.conf) | RabbitMQ satu node (tanpa daftar node klaster) |
| [`deploy/aws/cloudfront-dua-jalur.sh`](../deploy/aws/cloudfront-dua-jalur.sh) | CloudFront dua jalur, dipakai bersama versi 9 server (`W_DIR` memilih folder catatan) |
| [`deploy/lambda/siapkan-gambar.sh`](../deploy/lambda/siapkan-gambar.sh) | Lambda, S3, dan CloudFront gambar kutipan |
| [`PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md`](PANDUAN-CLOUDWATCH-DAN-STRESS-TEST.md) | Cara membuka dan membaca CloudWatch, cara menentukan titik jenuh dan titik hancur stress test |
| [`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md) | Versi Scalable 9 server |
