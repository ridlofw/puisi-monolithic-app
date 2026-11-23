# Panduan Deploy ke AWS Sandbox: 9 server, Docker Swarm, ALB, Lambda, CloudFront

**Untuk siapa:** siapa pun di tim yang ingin menjalankan seluruh aplikasi puisi (38 layanan) di AWS Academy Sandbox, dari nol sampai
bisa dibuka di browser lewat HTTPS. **Alat utamanya satu: AWS CLI di AWS CloudShell.** Hampir semua langkah lewat perintah; klik hanya untuk masuk ke lab, membuka CloudShell, dan mengunggah `kode.tgz`
(menu Actions), serta (opsional) menghentikan server lewat konsol EC2 pada uji ketahanan.

**Bagaimana dokumen ini dibuat:** setiap langkah di bawah dijalankan sungguhan di sandbox pada **23 November 2026**, dan angka waktunya adalah angka yang tampil
di layar. Bagian **11 (Status bukti)** jujur menandai langkah yang dijalankan persis seperti tertulis, dan langkah yang diubah sesudah dijalankan dan belum diulang
dari nol. **Cerita eksperimennya** (apa yang dicoba, apa yang gagal, kenapa keputusan diambil) ada di
[`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md); **bentuk sistemnya** (kenapa 9 server, kenapa layanan digabung begitu, hubungan antar-server) di
[`ARSITEKTUR-DEPLOY-AWS.md`](ARSITEKTUR-DEPLOY-AWS.md). Dokumen ini hanya berisi apa yang harus dikerjakan.

---

## 0. Hasil akhir

```
Browser --HTTPS--> CloudFront (satu alamat: https://dxxxx.cloudfront.net)
                     |-- /  /js/*  style.css  latar*.jpeg --> S3        (halaman; di-cache CloudFront)
                     |-- /fungsi*                        --> Lambda     (gambar kutipan)
                     |-- /api/*  /audio/*                --> ALB --> gateway (server 1-3) --> layanan (server 1-9)
```

| Server | Zona | Isi |
|---|---|---|
| `s1`, `s2`, `s3` (manager Swarm) | a, b, c | gateway, RabbitMQ 3 node, Redis, auto-tagging, analisis-emosi, **OpenSearch 3 node + HAProxy**, search-service, search-consumer, registry (di s1) |
| `s4`, `s5`, `s6` | a, b, c | poem-db (klaster MySQL 3 node + 2 router), poem-service, relay, consumer, klasifikasi-genre |
| `s7`, `s8`, `s9` | a, b, c | auth-db dan **tts-db** (dua klaster MySQL 3 node + router), auth-service, **text-to-speech** (1 worker), **SeaweedFS** (di s7) |

Hasil akhir yang terukur: **39 layanan penuh, 0 belum** (38 layanan aplikasi + registry), 9 node sehat, `scripts/uji_e2e.py` **10 dari 10 tahap lulus**
(juga bila dijalankan lewat alamat HTTPS CloudFront).

---

## 1. Aturan sandbox yang membentuk rancangan ini

Sandbox: **AWS Academy Cloud Developing 2.x, Sandbox**, region `us-east-1` (juga `us-west-2`).

| Aturan | Akibat |
|---|---|
| Lingkungan **sementara**: saat timer sesi habis (sekitar 3 jam) semua sumber daya **dihapus permanen** | Semuanya harus bisa diulang dalam satu sesi: itu sebabnya ada skrip. Mulai segera setelah **Start Lab** |
| Anggaran $40 (angka di layar tertinggal 8 sampai 12 jam). Pemakaian satu sesi penuh ini sekitar $2,5 | Cukup |
| EC2 hanya `t2/t3` ukuran `nano`, `micro`, `small` (**`t3.medium` dan `t3.large` ditolak AWS, terbukti**); **9 instance sekaligus per akun**: API menerima peluncuran lebih banyak, tetapi **sistem lab menghentikan kelebihannya dalam ± 10 detik, di region mana pun** (diuji 23 Nov sampai 38 instance) | **9 server × 2 GiB RAM**, tidak bisa ditambah. Analisis dan bukti: [`ARSITEKTUR-DEPLOY-AWS.md`](ARSITEKTUR-DEPLOY-AWS.md) bagian 2 |
| AMI harus milik Amazon | **Amazon Linux 2023** (bukan Ubuntu) |
| EBS maksimal 35 GB | 30 GiB dipakai |
| IAM: tidak bisa membuat role; `LabRole` dan `LabInstanceProfile` sudah ada | Dipakai untuk Lambda dan agar server bisa dikendalikan lewat **SSM** (tanpa kunci SSH) |
| ECS, EKS, **EFS**, ACM, Route 53 **tidak ada** | Tidak ada Fargate; data SeaweedFS di disk satu server; **ALB tidak bisa HTTPS**, jadi HTTPS lewat CloudFront |

Ingin memeriksa sandbox Anda sendiri sebelum mulai (hanya membaca, tidak membuat apa pun): `bash cek-sandbox.sh` (lihat Langkah 0).

---

## 2. Yang harus disiapkan

- Akun AWS Academy dengan lab **aktif** (tombol Start Lab sudah ditekan dan lampu AWS hijau).
- Repositori ini di laptop, cabang `main` terbaru **beserta folder `deploy/`**. Kode yang dikirim harus **berakhir baris LF**: `.gitattributes` repo sudah menjaganya
  untuk `*.sh`, `*.yaml`, `*.conf`. Akhir baris CRLF membuat bash gagal dengan `$'\r': command not found`.
- Waktu: eksekusi sekitar **1 jam** (kebanyakan menunggu), siapkan **1,5 jam** dari sesi 3 jam.
- **Privasi:** semua skrip menyaring keluarannya (nomor akun 12 digit, email, nama sesi, ID kunci). Tetap **jangan menempel nomor akun, email, atau kunci akses**
  ke chat, GitHub, atau tangkapan layar. Header console AWS memuat nomor akun: potong sebelum membagikan gambar.

**Tentang "hanya AWS CLI":** CloudShell sudah memasang AWS CLI dan mengisi kredensial sesi Anda, jadi tidak ada yang perlu dipasang atau dikonfigurasi.
Menjalankan dari laptop dimungkinkan (kredensial sementara dari panel lab, `aws configure`), tetapi skrip memakai `bash`, `python3`, `curl`, dan `sed` ala Linux
dan **tidak diuji di Windows**; pakai CloudShell.

---

## 3. Langkah 0: masuk dan buka CloudShell

1. Di halaman lab AWS Academy: **Start Lab**, tunggu lampu **AWS** menjadi hijau, klik **AWS**. Console terbuka.
2. Pastikan region **N. Virginia (us-east-1)**.
3. Klik ikon **CloudShell** (`>_`) di bilah atas, tunggu `~ $` muncul.
4. (Opsional, sesudah Langkah 1) Periksa sandbox: `bash ~/deploy/cek-sandbox.sh`. Hanya membaca, tidak membuat apa pun.

**Perilaku CloudShell yang perlu diketahui (semuanya terjadi saat dijalankan):**
- **Satu berkas per unggahan** dan **tidak menimpa** nama yang sudah ada (pakai nama baru lalu `mv -f`).
- Unggahan kedua berturut-turut dapat ditolak `Too Many Requests`: beri jeda sekitar satu menit.
- Sesi putus bila diam lama ("Sesi Anda telah berakhir"), dan lingkungan bisa `SUSPENDED` lalu menyala lagi (sekitar 1,5 menit; sebuah dialog selamat datang
  muncul, tutup saja). **Berkas di `~` tetap ada**, proses yang sedang berjalan hilang. Perintah yang lama jalan sebaiknya dijalankan sambil diamati, bukan ditinggal.
- Terminal lambat menampilkan keluaran. Tunggu, jangan menekan Enter berulang.
- **Jangan meluncurkan instance di luar 9 server**: sistem lab menghentikannya dalam detik (bagian 1; ARSITEKTUR bagian 2). Timer lab pernah naik kembali tanpa menghapus sumber daya (teramati 23 Nov: 00:49 menjadi 02:58; 9 server dan 39 layanan utuh); penyebabnya tidak saya pastikan, jadi jangan mengandalkannya.

---

## 4. Langkah 1: kemas kode dan bawa ke CloudShell

**Cara B (terbukti): unggah dari laptop.** Di laptop, dari akar repositori (Git Bash atau terminal lain yang punya `tar`):

```bash
tar czf kode.tgz --exclude=node_modules --exclude=__pycache__ --exclude=.git --exclude=secrets \
  services workers gateway web compose compose.yaml rabbitmq deploy scripts kontrak observability lambda
```

Di CloudShell: **Actions (Tindakan) → Upload file** → pilih `kode.tgz`. Lalu:

```bash
tar xzf ~/kode.tgz -C ~ deploy && cp ~/deploy/aws/*.sh ~/ && ls ~/*.sh
```

Harus tampil `9server.sh`, `alb.sh`, `bangun2.sh`, `bangun6.sh`, `cloudfront-dua-jalur.sh`, `https-cloudfront.sh`.

**Periksa akhir baris sebelum lanjut** (berkas yang dipakai Swarm sebagai config tidak boleh berubah isinya, dan CRLF mengubah isinya). Di CloudShell:

```bash
for f in rabbitmq/rabbitmq.conf rabbitmq/definitions.json services/puisi/db/init.sql services/puisi/db/init-cluster.sh deploy/swarm/mysql/klaster.cnf deploy/swarm/stack.yaml; do
  printf '%s CR=' "$f"; tar xzf ~/kode.tgz -O "$f" | tr -cd '\r' | wc -c
done
```

Semuanya harus `CR=0`. Bila ada yang bukan 0, ubah berkas itu ke LF di laptop (Git Bash: `sed -i 's/\r$//' <berkas>`) lalu kemas ulang. (`.gitattributes` sudah memaksa LF untuk `*.conf`, `*.json`, `*.yaml`, `*.sh`, `*.sql`;
`*.cnf` dan `*.cfg` belum tercakup, jadi periksa `klaster.cnf` khususnya.)

> **Kode di `main` sekarang sudah memuat perubahan Bab 10 dan 11 (Pison)** dan semua image memakai tag `v4` (gateway final `v4-gw`) sebagai bawaan. Bukti di bagian 11 yang tertulis `v1` sampai `v3`
> dihasilkan oleh kode sebelum perubahan itu. Baca bagian **10b** sebelum men-deploy.

**Cara A (belum pernah dijalankan; butuh `deploy/` sudah di-push ke GitHub):** hanya CloudShell, tanpa unggah.

```bash
git clone https://github.com/ridlofw/puisi-monolithic-app.git ~/puisi-monolithic-app && cd ~/puisi-monolithic-app
tar czf ~/kode.tgz --exclude=node_modules --exclude=__pycache__ --exclude=.git --exclude=secrets \
  services workers gateway web compose compose.yaml rabbitmq deploy scripts kontrak observability lambda
cp deploy/aws/*.sh ~/ && cd ~
```

---

## 5. Langkah-langkah deploy

Semua dijalankan di CloudShell, dari `~`. Setiap perintah `9server.sh` mencatat keadaan di `~/puisi9/` dan **aman diulang**. Waktu adalah waktu terukur.

### Tahap 1: dasar (23 layanan)

| # | Perintah | Yang terjadi | Waktu | Cek berhasil |
|---|---|---|---|---|
| 1 | `bash ~/9server.sh luncurkan` | Security Group `puisi-swarm-sg` (lalu lintas hanya dari grup itu sendiri) dan **9 `t3.small`** (Amazon Linux 2023, 30 GiB, zona a/b/c, `LabInstanceProfile`, user-data memasang Docker dan swap 3 GiB) | ± 2 menit | tabel 9 baris `puisi-s1` .. `puisi-s9` |
| 2 | `bash ~/9server.sh swarm` | Menunggu 9 server terdaftar di SSM (maks 10 menit) dan Docker siap; `swarm init` di s1; **s2 dan s3 manager**, s4 sampai s9 worker; memasang label | ± 8 menit | `docker node ls`: 9 `Ready`, 1 `Leader`, 2 `Reachable` |
| 3 | `bash ~/9server.sh kode` | Mengirim `~/kode.tgz` ke s1 lewat bucket S3 sementara (`puisi-kode-…`), diekstrak di `/opt/puisi` | < 1 menit | `diekstrak: kode.tgz` |
| 4 | `bash ~/9server.sh image` | Registry sendiri di Swarm (port 5000), lalu **6 image** dibangun di s1 di latar belakang: gateway, poem, auth, auto-tagging, klasifikasi-genre, analisis-emosi. **Jangan memakai `\| tail`** (menahan keluaran) | **2 m 47 d** (+ sampai 4 menit pertama menarik image registry) | `bash ~/9server.sh status` menampilkan `SELESAI` dan 6 baris `OK` |
| 5 | `bash ~/9server.sh deploy` | Membuat rahasia (`scripts/siapkan_rahasia*.py`), `docker stack deploy`, lalu **membuang 15 layanan** pencarian dan TTS (dipasang di tahap 2) | ± 4 menit | `bash ~/9server.sh cek`: 23 layanan penuh |
| 6 | `bash ~/9server.sh rabbit` | **Wajib.** RabbitMQ tidak otomatis berklaster di Swarm: node 2 dan 3 di-`join_cluster` ke node 1, lalu antrean quorum ditambah replika. Aman diulang (node yang sudah anggota dilewati) | ± 1 menit | tiga baris `rabbit@rabbitmq-1`, `-2`, `-3` |
| 7 | `bash ~/9server.sh verifikasi` | poem-db dan auth-db (masing-masing 3 ONLINE), RabbitMQ 3 node, gateway, `uji_e2e.py` | ± 1,5 menit | **8 dari 10** tahap lulus pada tahap 1 (`audio` dan `pencarian` belum ada) |
| 8 | `bash ~/alb.sh buat` | Security Group ALB, target group `puisi-tg` (health check `/healthz`), **ALB** internet-facing, listener 80, mendaftarkan s1 sampai s3 | ± 4 menit | `bash ~/alb.sh status`: 3 target `healthy`; alamatnya di `~/puisi9/alb-dns` |

### Gambar kutipan: Lambda, S3, CloudFront

| # | Perintah | Yang terjadi | Waktu | Cek berhasil |
|---|---|---|---|---|
| 9 | `mkdir -p ~/puisi-monolithic-app && tar xzf ~/kode.tgz -C ~/puisi-monolithic-app && cd ~/puisi-monolithic-app && bash deploy/lambda/siapkan-gambar.sh; cd ~` | Bucket S3 (akses publik, policy, website), fungsi Lambda `puisi-gambar` (`nodejs24.x`, `LabRole`, Function URL), berkas latar, distribusi CloudFront dengan kebijakan cache. Keadaan dicatat di `~/.puisi-gambar.state` | < 10 menit | `uji lulus: 2 dari 2` dan baris `CDN_URL=https://dxxxx.cloudfront.net` |

Berkas latar dosen (`latar1.jpeg`, `latar2.jpeg`, `latar3.jpeg`, `latar5.jpeg`) tidak ada di repositori. Letakkan di folder `latar/` (di folder tempat skrip dijalankan) **sebelum** menjalankan skrip;
tanpa itu skrip membuat latar pengganti polos. Membuka alamat akar distribusi ini menampilkan `NoSuchKey`: **normal** (bucket hanya berisi latar); aplikasi ada di alamat dua jalur (langkah 17).

### Gateway dengan alamat gambar dan IP pengunjung

| # | Perintah | Yang terjadi | Waktu | Cek berhasil |
|---|---|---|---|---|
| 10 | `bash ~/9server.sh gateway` | Membangun image gateway final **`v4-gw`** (`GATEWAY_TAG`; pada bukti 23 Nov: `v3`): `CDN_URL` (dari langkah 9) dan rentang IP CloudFront (`deploy/swarm/gateway/buat-cloudfront-conf.sh`: 217 IPv4 + 35 IPv6, supaya batas login **dan batas kirim puisi/pencarian** dihitung **per pengunjung**, bukan per edge CloudFront), lalu rolling update 3 gateway | ± 2 menit | `docker service ps puisi_gateway`: tiga task `puisi-gateway:v4-gw`. **Wajib sebelum langkah 12**: `override-9server.yaml` menunjuk `:${GATEWAY_TAG}` |

### Tahap 2: pencarian dan text-to-speech (menjadi 38 layanan)

**Jangan menjalankan `deploy` lagi untuk tahap ini**: `deploy` justru membuang layanan-layanan itu.

| # | Perintah | Yang terjadi | Waktu | Cek berhasil |
|---|---|---|---|---|
| 11 | `bash ~/9server.sh image2` | Membangun `puisi-pencarian` dan `puisi-tts` di s1 (latar belakang; `puisi-tts` mengunduh model suara Piper dari huggingface.co) | pencarian **21 d**, tts **1 m 47 d** | `bash ~/9server.sh jalankan 1 'cat /opt/puisi/build2.log'` berakhir `SELESAI` dengan dua `OK` |
| 12 | `bash ~/9server.sh stack2` | `docker stack deploy -c stack.yaml -c override-9server.yaml`. Layanan baru berstatus `0/1` (menunggu label, belum memakai memori) | ± 1,5 menit | baris pertama menampilkan `puisi-gateway:v4-gw`; bagian "task layanan lama yang baru dimulai" **kosong** pada deploy dari nol (tidak ada layanan lama yang ikut diganti) |
| 13 | `bash ~/9server.sh pasang pencarian` | `vm.max_map_count=262144` di s1 sampai s3 (wajib bagi OpenSearch; bawaan 65530) dan label `puisi.pool.pencarian` | klaster hijau ± 2 menit | `bash ~/9server.sh jalankan 1 'docker exec $(docker ps -qf name=puisi_opensearch-1) curl -s -m 8 localhost:9200/_cluster/health'`: `"status":"green"`, 3 node; `search-service` 2/2 |
| 14 | `bash ~/9server.sh pasang tts` | Label `puisi.pool.tts` di s7 sampai s9 dan `puisi.audio` di s7 (server lain: `AUDIO_DI=8 bash ~/9server.sh pasang tts`) | ± 3 menit | klaster tts-db 3 ONLINE; `seaweedfs` dan `text-to-speech` 1/1 |
| 15 | `bash ~/9server.sh hitung` | Menghitung layanan yang belum penuh dan keadaan node | beberapa detik | `39 layanan penuh, 0 belum; total 39` dan 9 node (1 Leader, 2 Reachable, 6 Ready) |

**Bila langkah 14 atau 15 menunjukkan layanan TTS yang tetap `0/1` (Pending):** penjadwal tidak selalu mencoba ulang setelah label dipasang. Dorong:

```bash
bash ~/9server.sh jalankan 1 'for s in tts-db-1 tts-db-2 tts-db-3 seaweedfs text-to-speech tts-db-router; do docker service update --force --detach puisi_$s; done'
```

Bila `tts-db-router` masih `1/2` (replika kedua macet `Pending`), buang lalu buat ulang:
`bash ~/9server.sh jalankan 1 'docker service scale --detach puisi_tts-db-router=1; sleep 6; docker service scale --detach puisi_tts-db-router=2'`, lalu `hitung` lagi.
Selalu jalankan `hitung` setelah memasang: replika yang macet tidak terlihat dari luar.

### Uji ujung ke ujung dan HTTPS

| # | Perintah | Yang terjadi | Waktu | Cek berhasil |
|---|---|---|---|---|
| 16 | `bash ~/9server.sh verifikasi` | Klaster MySQL, RabbitMQ, gateway, `uji_e2e.py --tunggu 150` | ± 2 menit | **`10 dari 10 tahap LULUS`**, termasuk `audio` (`GET /audio/puisi_N.mp3 -> 200`) dan `pencarian` |
| 17 | `mkdir -p ~/puisi9 && tar xzf ~/kode.tgz -C ~/puisi9 web && bash ~/deploy/aws/cloudfront-dua-jalur.sh buat` | **CloudFront dua jalur**: asal S3, ALB, dan Lambda; mengunggah `web/` ke S3 dengan alamat distribusi disisipkan ke **salinan** `api.js`; menunggu `Deployed`; menguji | ± 8 menit | `uji lulus: 8 dari 8` dan `ALAMAT APLIKASI (HTTPS): https://dxxxx.cloudfront.net/` |
| 18 | `tar xzf ~/kode.tgz -C ~/puisi9 scripts/uji_e2e.py && cd ~/puisi9 && GATEWAY=https://$(cat ~/puisi9/cf-dua-dns) python3 scripts/uji_e2e.py --tunggu 150; cd ~` | Uji ujung ke ujung **dari luar server**, lewat alamat HTTPS | ± 1 menit | **10 dari 10** |

Jalur yang dibuat langkah 17:

| Jalur | Tujuan | Cache |
|---|---|---|
| `/`, `/js/*`, `style.css`, `latar*.jpeg` | **S3** (website endpoint) | TTL 60 detik (kebijakan `puisi-StatisPendek`) |
| `/fungsi*` | **Lambda** (Function URL) | kebijakan dari langkah 9 |
| `/api/*` | **ALB** → gateway → layanan | mati (`CachingDisabled`); semua header diteruskan |
| `/audio/*` | **ALB** → gateway → SeaweedFS | `CachingOptimized` |

Mengubah frontend setelah ini: `bash ~/deploy/aws/cloudfront-dua-jalur.sh unggah` (terlihat paling lama 60 detik kemudian). **Cadangan:** bila langkah 17 gagal,
`bash ~/https-cloudfront.sh buat` membuat distribusi satu asal (semua lewat ALB; HTTPS saja, tanpa S3).

---

## 6. Mencoba aplikasi

1. Buka `https://dxxxx.cloudfront.net/` (alamat dari langkah 17). Halaman Login dan Register muncul.
2. **Register** satu akun, lalu **Login**. Kirim satu puisi (judul, isi; kutipan untuk gambar).
3. Tunggu sekitar 30 detik, muat ulang galeri. Kartu puisi memuat tag, genre, emosi, dan pemutar audio (`<audio controls>`; sumbernya `/audio/puisi_N.mp3`).
4. Kotak pencarian menemukan puisi yang baru dikirim (puisi yang dikirim **sebelum** pencarian dipasang tidak terindeks).

---

## 7. Memantau

| Perintah | Menunjukkan |
|---|---|
| `bash ~/9server.sh hitung` | layanan yang belum penuh (harus 0) dan keadaan node |
| `bash ~/9server.sh cek` | node, semua layanan dan replikanya, memori tiap server |
| `bash ~/9server.sh memori` | memori semua server sekaligus (terpakai, tersedia, swap, beban) |
| `bash ~/9server.sh jalankan <no> '<perintah>'` | perintah apa pun di server nomor itu lewat SSM |

Memori terukur dengan 38 layanan (sesudah satu uji ujung ke ujung): s1 sampai s3 tersedia 524 sampai 568 MB; s4 sampai s6 516 sampai 629 MB; **s7 sampai s9 267 sampai 426 MB**
dan memakai swap sampai 397 MB (paling ketat). Lihat batasnya di bagian 10.

---

## 8. Uji ketahanan (opsional): matikan satu server

Terbukti hanya dengan **23 layanan** (belum dengan 38). Pantau lewat ALB satu kali per detik di CloudShell:

```bash
DNS=$(cat ~/puisi9/alb-dns); while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -m 4 -w '%{http_code}\n' "http://$DNS/healthz"; sleep 1; done | tee ~/puisi9/mon.log
```

Matikan server dengan **Stop** (bukan Terminate) lewat konsol EC2 (cara yang dijalankan), atau:
`aws ec2 stop-instances --instance-ids $(awk -F'\t' '$1=="puisi-s4"{print $2}' ~/puisi9/servers.tsv)` (**CLI belum dijalankan**), dan `start-instances` untuk menyalakan.
Hasil terukur saat s4 (PRIMARY poem-db) dimatikan: 0 dari 258 probe gagal, PRIMARY pindah otomatis, server pulih dan bergabung kembali dalam sekitar 100 detik.
Detailnya di [`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md). Setelah server hidup lagi, bila anggota klaster MySQL tidak `ONLINE`:
`docker service update --force puisi_poem-db-cluster-init` (atau `auth-db`/`tts-db`).

**Tambahan sejak kode Pison (probe tulis).** Probe di atas (`GET /healthz`, dan di bukti lama `GET /api/puisi` yang bisa dilayani dari cache gateway) hampir tidak menyentuh database, padahal
perubahan Pison justru ada di jalur database (circuit breaker, koneksi persisten, batas baca 3 detik). Jalankan juga pemantau tulis di CloudShell **sambil** mematikan s4:

```bash
GATEWAY=http://$(cat ~/puisi9/alb-dns) python3 ~/deploy/aws/uji-ketahanan-baru.py pantau --detik 600 --selang-tulis 5 | tee ~/puisi9/mon-tulis.log
```

Satu `GET /api/puisi` per detik dan satu `POST /api/puisi` berkunci (`Idempotency-Key`) tiap 5 detik, dengan kirim ulang bila `5xx` atau putus (seperti `web/js/kirim.js`). Barisnya `HH:MM:SS get=200 tulis=202`;
ringkasannya mencetak jumlah GET dan tulis yang gagal. Skrip ini dijalankan di AWS 23 Nov 2026 (hasil di bagian 11: 480 GET dan 96 tulis, 0 gagal saat s6 dimatikan). Pengambilan contoh tiap 5 detik untuk tulis, jadi gangguan yang lebih pendek dari sekitar 5 detik bisa terlewat. Bandingkan hasilnya dengan bukti lama (0 dari 258) dan catat hash commit-nya.
Bawaannya membuat sekitar 120 puisi uji dalam 10 menit, dan tiap puisi memicu pekerjaan analisis dan suara di server yang paling ketat; untuk beban lebih ringan pakai `--selang-tulis 10`.

### 8b. Membersihkan

**Semua hilang sendiri saat timer lab habis**, jadi membersihkan hanya perlu bila ingin berhenti lebih awal atau mengulang di sesi yang sama. Urutan penting (CloudFront dulu, server terakhir):

```bash
YA=1 bash ~/deploy/aws/cloudfront-dua-jalur.sh hapus      # distribusi dua jalur (menonaktifkan lalu menunggu; beberapa menit)
YA=1 bash ~/https-cloudfront.sh hapus                     # hanya bila rancangan satu asal dibuat
YA=1 bash ~/alb.sh hapus
cd ~/puisi-monolithic-app && YA=1 bash deploy/lambda/siapkan-gambar.sh hapus; cd ~   # bucket gambar, Lambda, distribusi gambar
YA=1 bash ~/9server.sh hapus                              # 9 server dan Security Group puisi-swarm-sg
aws s3 rb s3://$(cat ~/puisi9/bucket) --force             # bucket kode sementara
```

Kebijakan cache `puisi-StatisPendek` dan `puisi-CacheWithQueryString` boleh dibiarkan (tidak berbiaya). Biaya 9 `t3.small` sekitar $0,19 per jam menurut tarif standar (**tidak diverifikasi**);
seluruh sesi ini memakai sekitar $2,5 menurut penghitung lab (angkanya tertinggal 8 sampai 12 jam). **Perintah `hapus` belum pernah dijalankan** (lingkungan dipakai sampai timer habis): jalankan sambil diamati.

---

## 9. Pemecahan masalah

| Gejala | Penyebab | Tindakan |
|---|---|---|
| `$'\r': command not found`, `syntax error near unexpected token` saat menjalankan `.sh` | berkas berakhir baris CRLF (dikemas dari Windows tanpa `.gitattributes`) | `sed -i 's/\r$//' ~/*.sh ~/deploy/aws/*.sh`, atau kemas ulang dari berkas LF |
| `UnauthorizedOperation ... ec2:RunInstances` | ukuran selain `t2/t3` ≤ small, atau lebih dari 9 instance | jangan mengubah `TIPE` (`t3.small`); diagnosis tanpa membuat apa pun: `bash cek-launch.sh` |
| `swarm`: "SSM belum melihat 9 server" | agen SSM belum siap | tunggu 2 sampai 3 menit, ulangi `swarm` (aman diulang) |
| `image`: keluaran kosong beberapa menit | registry menarik image pertama sampai ± 4 menit | bukan galat; pantau `bash ~/9server.sh status`; jangan memakai `\| tail` |
| `no suitable node (scheduling constraints not satisfied)` | label belum dipasang, atau pesan lama yang tidak diperbarui | pasang label (`pasang pencarian` / `pasang tts`); bila label benar tetapi tetap `Pending`: `docker service update --force --detach puisi_<layanan>`; replika yang masih kurang satu: `docker service scale` turun lalu naik (langkah 15) |
| `opensearch-N` tetap `0/1`; log `UnknownHostException: opensearch-2` dan `cluster_manager_not_discovered_exception` | healthcheck lama `/_cluster/health` membuat kebuntuan DNS di Swarm | pastikan `deploy/swarm/stack.yaml` terbaru (healthcheck `curl -fs -o /dev/null http://localhost:9200/`). **Tidak bisa diperbaiki lewat berkas override kedua** (daftar `test` digabung dengan menambahkan) |
| OpenSearch mati terus, log `vm.max_map_count [65530] is too low` | pengaturan kernel belum diatur | `bash ~/9server.sh pasang pencarian` |
| Pencarian kosong padahal OpenSearch hijau | `search-service` menyerah menunggu OpenSearch saat start | `docker service update --force puisi_search-service`. Puisi lama (sebelum pencarian dipasang) memang tidak terindeks |
| RabbitMQ kurang dari 3 node | node 2 dan 3 membentuk klaster sendiri | `bash ~/9server.sh rabbit` (`docker service update --force` **tidak** memperbaikinya) |
| `only updates to Labels are allowed` saat `stack deploy` | isi berkas yang dipakai Swarm config/secret berubah (mis. mengekstrak kode penuh yang baru di atas server yang berjalan) | kirim hanya berkas yang berubah: `tar czf arsip.tgz <berkas>` lalu `bash ~/9server.sh kode ~/arsip.tgz`; jangan ekstrak ulang arsip penuh |
| Gateway tidak naik setelah `stack2`; image `puisi-gateway:v4-gw` tidak ada | langkah 10 dilewati, atau `TAG`/`GATEWAY_TAG` berbeda antara `gateway` dan `stack2` | jalankan langkah 10 dengan `TAG` yang sama, atau `GATEWAY_TAG=<tag yang ada> bash ~/9server.sh stack2` |
| Login `429` | batas 10 per menit per IP | tunggu semenit. Bila **semua** pengguna kena sekaligus, IP klien tidak terbaca: pastikan gateway final `v4-gw` (langkah 10) |
| Kirim puisi atau pencarian `429` (`Terlalu banyak permintaan`, header `Retry-After: 1`) | throttle gateway (kode Pison): 5 kirim puisi per detik (burst 30) dan 30 pencarian per detik (burst 60), **per IP dan per gateway** (3 gateway: sekitar 3 kali lipat) | normal untuk uji beban dari satu IP (CloudShell atau server 1 berbagi satu ember). Bila **banyak pengunjung berbeda** kena bersamaan, IP klien tidak terbaca: pastikan `01-cloudfront.conf` ikut terbangun (langkah 10) |
| Kirim puisi gagal `5xx` hanya sesudah memperbarui kode; log poem-service berisi `Too many connections` atau `server has gone away` | koneksi database persisten (bawaan kode Pison) bertemu batas `max_connections = 100` atau koneksi basi sesudah failover | tombol darurat `DB_PERSISTEN: "0"` (poem) dan `DB_PERSISTENT: "0"` (auth) di `override-9server.yaml` (lihat bagian 10b) |
| Halaman terbuka tetapi API menjawab `503 Layanan untuk rute ini belum dijalankan` | layanan di balik rute itu belum dipasang | selesaikan tahap 2 (langkah 11 sampai 15) |
| Puisi terus berstatus "diproses" | worker tag/genre/emosi/tts belum jalan atau antrean menumpuk | `docker service ls`; `docker exec $(docker ps -qf name=puisi_rabbitmq-1) rabbitmqctl list_queues name messages consumers` |
| CloudFront: `NoSuchKey` di akar distribusi dari langkah 9 | normal: bucket hanya berisi latar | pakai alamat dari langkah 17 |
| CloudShell: `Too Many Requests` saat unggah; `SUSPENDED` | batas laju unggahan; lingkungan tidur karena diam | beri jeda; tunggu lingkungan menyala, ulangi |
| Semua hilang di tengah jalan | timer lab habis | mulai lagi dari **Start Lab**; `kode.tgz` di laptop tetap ada |

---

## 10. Batasan yang diketahui (jangan ditulis sebagai "bebas SPOF")

- **SeaweedFS (audio) satu proses di satu server** (`s7`): bila server itu mati, audio berhenti sampai hidup lagi. EFS (`stack.efs.yaml`) tidak tersedia di sandbox.
- Redis satu salinan (hanya cache). Worker suara 1 replika. `tts-db-router` 2 replika.
- **Server 7 sampai 9 paling ketat** (tersedia 267 sampai 426 MB, swap sampai 397 MB). Tidak ada server yang mati, tetapi ini diukur **diam dan sesudah satu uji ujung ke ujung**, bukan di bawah beban banyak pengguna.
  Menambah replika worker suara atau memperbesar heap OpenSearch (384 MB; bawaan `stack.yaml` 512 MB) tidak akan muat.
- ALB masih bisa dijangkau langsung lewat HTTP (tanpa HTTPS). Menutupnya: batasi Security Group ALB ke prefix list `com.amazonaws.global.cloudfront.origin-facing` (belum dikerjakan).
- Puisi yang dikirim sebelum pencarian dipasang tidak terindeks (9 pesan di `q.pencarian-indeks.dlq` belum diputar ulang).
- Observability (Prometheus, Grafana, Loki), k6, dan CI ke GHCR belum ada.
- Batas 9 instance berarti tidak ada server ke-10 untuk menunjukkan scale-out.
- **Sejak kode Pison:** model suara Piper dimuat terus-menerus di worker TTS (satu replika di salah satu server 7 sampai 9, yang paling ketat; pada bukti lama s8); koneksi database dipakai ulang (persisten) padahal `max_connections` MySQL hanya 100;
  throttle gateway dihitung per gateway (3 gateway: kira-kira 3 kali lipat dari angka yang tertulis di kode). Memori dan throttle sudah terukur di AWS (bagian 11); yang BELUM adalah perilakunya di bawah beban banyak pengguna (batas `max_connections`). Lihat bagian 10b.

---

## 10b. Perubahan kode Pison (Bab 10 dan 11) dan akibatnya pada deploy

**Konteks.** Bukti di bagian 11 dihasilkan oleh kode pada commit `6eee96a` (PR #6; laporan mencatat bahwa hanya 9 berkas PR #6 yang dikirim ke server). Sesudahnya Pison menambah 13 commit (71 berkas, sampai `10ba055`) yang kini sudah ada di `main`.
**Berkas deploy (`deploy/`), `stack.yaml`, dan semua sumber Swarm config/rahasia tidak berubah** (diperiksa terhadap daftar `configs:` di `stack.yaml`: `rabbitmq/*`, `init.sql`, `init-cluster.sh`, `schema.sql`, `klaster.cnf`, `haproxy.cfg`, `init-innodb-cluster.sh`). Urutan langkah di bagian 5 tetap sama.
Yang berubah: **semua 8 image harus dibangun ulang** dan beberapa perilaku baru perlu diuji di AWS.

| Perubahan Pison | Akibat pada deploy AWS | Tindakan |
|---|---|---|
| Throttle gateway: `POST /api/puisi` 5 per detik (burst 30), `GET /api/search` 30 per detik (burst 60), per IP; kelebihan dijawab `429` JSON dengan `Retry-After: 1` | Ikut otomatis (`Dockerfile.gateway` menyalin `nginx.conf` dan `rute/`; `nginx -t` saat build). Ember dihitung **per gateway**, jadi dengan 3 gateway kira-kira 3 kali lipat per IP. Kuncinya IP pengunjung hanya bila `01-cloudfront.conf` ada (langkah 10) | `ujibaru` menguji 429. Uji beban dari satu IP (CloudShell, server 1) pasti melihat 429: wajar |
| `Idempotency-Key` + tabel `idempotensi` | Tabel dibuat `poem-relay` saat start lewat primary (user `poem` berhak `CREATE`; tereplikasi). `init.sql` tidak berubah. CloudFront memakai Managed-AllViewer untuk `/api/*`, jadi header ini sampai ke gateway. Halaman dari S3 harus diunggah ulang (`kirim.js` baru); urutan rilis bebas, kode lama dan baru sama-sama aman tanpa header | `ujibaru` memeriksa tabel di 3 node dan perilaku kunci. `cloudfront-dua-jalur.sh unggah` untuk halaman |
| Koneksi database persisten, batas baca 3 detik, circuit breaker (poem dan auth) | Aktif bawaan. `max_connections` MySQL = 100. Uji matikan PRIMARY dengan koneksi persisten dijalankan di AWS (bagian 11): 0 tulis gagal pada pengambilan contoh 5 detik; beban banyak pengguna BELUM diuji. Status breaker disimpan di `/tmp` kontainer (aman di Swarm, hilang saat task diganti) | Ulangi uji matikan s4 dengan probe tulis (bagian 8). Tombol darurat di `override-9server.yaml` |
| Worker TTS memuat model Piper sekali dan memanaskannya saat start | Memori worker naik permanen di server yang menjalankannya (satu dari s7 sampai s9; pada bukti lama s8); server 7 sampai 9 sudah paling ketat | `ujibaru` mencetak memori; tombol darurat `TTS_ENGINE: cli` |
| Pencarian: breaker OpenSearch, hasil basi dari Redis, consumer paralel di Compose | Ikut otomatis. Override tetap 1 `search-consumer` (memori) | Opsional: 3 replika bila `memori` mengizinkan |
| Retry dengan jitter di semua consumer dan worker; metrik durasi per request di Redis | Ikut otomatis; satu operasi Redis tambahan per request API | Tidak ada |
| **Tidak dibawa ke AWS:** gateway ganda VRRP/keepalived (`gateway-2`, `gateway/Dockerfile`), edit `compose/*.yaml`, Prometheus `dns_sd`, alert P99, dashboard Grafana | Swarm memakai `deploy/swarm/Dockerfile.gateway` (nginx polos) dan 3 gateway di belakang ALB; VPC AWS tidak meneruskan IP mengambang; stack ini tidak punya Prometheus atau Grafana | Jangan mengalihkan build Swarm ke `gateway/Dockerfile` |

**Men-deploy dari nol.** Langkah 1 sampai 18 sama seperti di atas; `TAG` bawaan `v4`, gateway final `v4-gw`. Setelah langkah 16 dan 18 jalankan `bash ~/9server.sh ujibaru`.

**Memperbarui sistem yang sedang berjalan** (tanpa mulai dari nol; **dijalankan di AWS 23 Nov 2026**, hasilnya di bagian 11). Image kode lama (`v1`, gateway `v3`) tetap ada di registry, jadi pembaruan ini bisa dibatalkan:
`TAG=v1 GATEWAY_TAG=v3 bash ~/9server.sh stack2` mengembalikan semua layanan aplikasi ke kode sebelum perubahan Pison (tabel `idempotensi` yang sudah terbentuk tidak mengganggu kode lama).

```bash
# di laptop (Git Bash), dari akar repositori: hanya berkas yang berubah sejak kode yang dibuktikan, TERMASUK berkas yang belum di-commit dan berkas baru
# (mis. deploy/aws/uji-ketahanan-baru.py). Tidak ada sumber Swarm config di dalamnya. (Atau commit dulu lalu pakai `git diff ... HEAD`.)
{ git diff --name-only --diff-filter=ACMR 6eee96a -- services workers gateway web compose scripts kontrak observability deploy/aws
  git ls-files --others --exclude-standard -- deploy/aws; } | sort -u > daftar.txt
tar czf arsip-pison.tgz -T daftar.txt
# di CloudShell, sesudah mengunggah arsip-pison.tgz:
bash ~/9server.sh kode ~/arsip-pison.tgz
# WAJIB: CloudShell masih memegang 9server.sh LAMA (dari kode.tgz langkah 4: tidak mengenal TAG dan tidak punya `ujibaru`). Ambil yang baru:
tar xzf ~/arsip-pison.tgz -C ~ deploy/aws && cp ~/deploy/aws/*.sh ~/
TAG=v4 bash ~/9server.sh image        # tunggu: bash ~/9server.sh status menampilkan SELESAI
TAG=v4 bash ~/9server.sh image2       # tunggu: bash ~/9server.sh jalankan 1 'cat /opt/puisi/build2.log'
TAG=v4 bash ~/9server.sh gateway
TAG=v4 bash ~/9server.sh stack2       # layanan yang image-nya berganti ikut diganti bergulir; basis data tidak boleh ikut
tar xzf ~/arsip-pison.tgz -C ~/puisi9 web && bash ~/deploy/aws/cloudfront-dua-jalur.sh unggah
bash ~/9server.sh hitung && bash ~/9server.sh verifikasi && bash ~/9server.sh ujibaru
```

Pakai `TAG` yang **sama** di semua perintah itu (bawaan `v4`; tag baru berikutnya, mis. `v5`, harus ditulis di keempat perintah). Bila `TAG` terlewat di salah satunya, `stack2` memasang image bertag bawaan.

**Pelajaran dari AWS (23 Nov 2026):** `image` versi lama menggantung tanpa akhir pada sistem yang sudah berjalan. Penyebabnya bukan registry (isinya utuh, `docker push/pull localhost:5000` normal), melainkan `curl http://localhost:5000` di shell SSM:
`localhost` diterjemahkan ke `::1` lebih dulu dan tidak dijawab (port itu hanya ditahan `dockerd`). Skrip kini memakai `127.0.0.1` dengan batas waktu, dan tidak lagi memasang ulang registry bila sudah ada.
**Perbaikan itu belum diuji sebagai skrip**; pada percobaan di AWS, langkah `image` dijalankan manual. Bila `image` menggantung, tekan Ctrl+C, lalu jalankan:
`bash ~/9server.sh jalankan 1 "cd /opt/puisi && : > build.log && (TAG=v4 setsid nohup bash deploy/aws/bangun6.sh > build.log 2>&1 < /dev/null &)"` (lalu `bash ~/9server.sh status`).

**Uji tambahan yang harus dijalankan sebelum menyebut deploy ini "terbukti":**

1. `bash ~/9server.sh ujibaru`: poem-db 3 ONLINE, tabel `idempotensi` ada di tiap node, kunci yang sama menghasilkan satu puisi (`Idempotent-Replay: true`), isi berbeda dengan kunci sama `409`, `429` muncul pada banjir `POST`, memori worker suara.
2. Uji matikan server pemegang PRIMARY poem-db (cek dulu dengan `verifikasi`; s4 pada deploy awal, **s6** pada percobaan 23 Nov) dengan **probe tulis** (bagian 8, `uji-ketahanan-baru.py pantau`). Penghentian lewat CLI (`aws ec2 stop-instances` dan `start-instances`) berhasil di CloudShell.
3. Satu `uji_e2e.py` 10 dari 10 sesudah itu (`verifikasi`).

**Catatan untuk Pison:** `poem-relay` kini membuat tabel `idempotensi` saat start. Pada deploy dari nol di Swarm (tanpa `depends_on`), relay bisa menyala sebelum klaster terbentuk dan membuat tabel di node yang belum bergabung.
`init-cluster.sh` mencoba `incremental` lalu jatuh ke `clone`, jadi seharusnya aman, tetapi urutan ini belum pernah dijalankan; `ujibaru` mengecek hasil akhirnya.

---

## 11. Status bukti

| Langkah | Status |
|---|---|
| 1 luncurkan, 3 kode, 4 image, 5 deploy, 8 alb, 9 siapkan-gambar, 11 image2, 13 pasang pencarian, 14 pasang tts | **Dijalankan di AWS 23 Nov 2026 persis seperti tertulis** |
| 2 swarm | Dijalankan; pemeriksaan `grep -q active` diperbaiki menjadi `grep -qx active` sesudah menemukan bug, lalu dijalankan ulang |
| 6 rabbit | Dijalankan: jalur manual dan jalur "lewati" (node sudah anggota). Jalur "bergabung" versi berpenjaga **belum diuji sebagai skrip** (langkahnya identik dengan manual) |
| 7 verifikasi, 16 verifikasi | Dijalankan: 8/10 pada tahap 1, dan **10/10** dengan versi skrip terbaru (`--tunggu 150`, pengujian ulang di bawah) |
| 10 gateway | Perintah-perintahnya dijalankan manual (v2, lalu v3: rolling update sungguhan, tiga task `v3`). Sebagai **skrip** dijalankan sekali pada pengujian ulang, tetapi image-nya identik dengan yang berjalan, jadi **penggantian task lewat skrip belum terbukti** |
| 12 stack2 | Versi pertama dijalankan di tahap 2. Versi terbaru dijalankan ulang: gateway tetap `v3`, tidak ada layanan lama diganti, tetapi pemeriksaan "task baru" memberi **positif palsu** (lihat di bawah); polanya sudah diperbaiki dan diuji di laptop, **versi perbaikannya belum dijalankan di AWS** |
| 15 hitung | **Dijalankan: `39 layanan penuh, 0 belum; total 39`**, 6 `Ready`, 1 `Leader`, 2 `Reachable` |
| 17 cloudfront-dua-jalur | Dijalankan: 8/8 uji. Lalu `uji()` diperbaiki (peringatan `null byte`) dan **dijalankan ulang: 8/8 tanpa peringatan** (distribusi yang ada dipakai ulang) |
| 18 e2e lewat CloudFront | **Dijalankan: 10/10** |
| Cara A (`git clone`) | **Belum pernah dijalankan** |
| Bagian 8 (uji ketahanan) | Dijalankan dengan 23 layanan, lewat konsol EC2. **Belum dengan 38 layanan**, dan versi CLI belum dijalankan |
| Bagian 8b (membersihkan, semua perintah `hapus`) | **Belum pernah dijalankan** |
| **Deploy ulang dari nol memakai dokumen ini dalam satu kali jalan** | **BELUM.** Tahap 2 dikerjakan di atas tahap 1 yang sedang berjalan, dan urutan "langkah 10 sebelum 11 sampai 15" baru berlaku sesudah override menunjuk `v3` |

**Pengujian ulang (sore 23 Nov 2026, pada sistem yang sama yang sedang berjalan, memakai skrip terbaru):**

| Yang dijalankan | Hasil |
|---|---|
| `kode <arsip>` lalu `stack2` | gateway tetap `v3`; layanan baru tidak ada yang diubah. **Positif palsu:** pemeriksaan "task baru dalam 5 menit" menandai `tts-db-router.2` (berumur 31 menit) karena pola `[1-5] minutes` ikut cocok dengan "31 minutes". Pola kini diawali `Running ...` dan diuji di laptop terhadap sembilan contoh; belum dijalankan ulang di AWS |
| `hitung` | `39 layanan penuh, 0 belum; total 39`; 9 node sehat |
| `gateway` (sebagai skrip) | membangun dan mendorong `v3`, memperbarui layanan; image sama, jadi tidak ada task yang diganti |
| `cloudfront-dua-jalur.sh buat` (distribusi sudah ada) | web diunggah ulang; **8 dari 8** lulus; peringatan `null byte` hilang |
| `verifikasi` | auth-db 3 ONLINE, RabbitMQ 3 node, gateway sehat, **`uji_e2e.py` 10 dari 10** |

**Kecelakaan yang tercatat saat pengujian ulang:** skrip yang saya sunting lewat Python di Windows tersimpan dengan akhir baris CRLF, dan di CloudShell bash gagal dengan
`$'': command not found` **sebelum satu pun perintah AWS berjalan** (hanya sebuah folder `~/puisi9` sampah yang terbentuk, sudah dihapus). Dikembalikan ke LF dan diuji ulang. Pelajarannya ada di bagian 9.

**Semua baris di atas adalah bukti untuk kode pada commit `6eee96a`**, sebelum 13 commit Pison (Bab 10 dan 11, `10ba055`) digabung. Tag `v1` sampai `v3` milik kode itu; bawaan skrip sekarang `v4` / `v4-gw`.

**Sesudah perubahan Pison, DIJALANKAN di AWS 23 Nov 2026 (sistem 39 layanan yang sedang berjalan diperbarui di tempat; kode `10ba055` sampai `main` terbaru, tag `v4`/`v4-gw`):**

| Yang dibuktikan | Hasil |
|---|---|
| Kondisi awal (kode lama, sebelum menyentuh apa pun) | `hitung`: 39 layanan penuh, 0 belum; poem-db dan auth-db 3 ONLINE; RabbitMQ 3 node; `uji_e2e.py` **10 dari 10**. Kode di server sama dengan commit `6eee96a` (checksum 6 berkas cocok; satu berkas JS hanya beda akhir baris CRLF) |
| Image dibangun (6 + 2, tag `v4`) dan gateway `v4-gw` | Semua `OK` (detik, karena lapisan di-cache). Isi image diperiksa: `CircuitBreaker.php`, `Pemutus.php`, `Skema.php` ada. `nginx -t` lolos saat membangun gateway dengan konfigurasi throttle Pison; 217 IPv4 + 35 IPv6 CloudFront terbaca |
| `stack2` (pembaruan bergulir) | `hitung`: **39 layanan penuh, 0 belum**; hanya layanan aplikasi yang berganti, dari yang diperiksa (`gateway v4-gw`, poem-service/relay/consumer, auth, pencarian, TTS, tiga worker: `v4`); basis data, RabbitMQ, OpenSearch tidak berganti |
| Lalu lintas selama pembaruan | Lewat ALB selama `stack2` bergulir (pemantau 17:19 sampai 17:26 UTC; pembaruan gateway sebelumnya tidak ikut terpantau, hanya diperiksa `healthz`, `/api/puisi`, `/sehat-gateway` = 200): **400 GET dan 80 tulis berkunci, 0 gagal, 0 kirim ulang** |
| `ujibaru` | **9 dari 9 pemeriksaan lulus**: tabel `idempotensi` ada di poem-db-1/2/3 (lewat kode Pison: relay membuatnya saat start melalui primary, tereplikasi); kunci sama menghasilkan id sama dan `Idempotent-Replay: true`; isi beda `409`; kunci pendek `400`; 120 GET tanpa 429; 300 POST cepat: 28 diteruskan (401), 272 dibatasi `429` JSON dengan `Retry-After: 1` |
| Lewat CloudFront (HTTPS) | Halaman baru diunggah ke S3 (`unggah`). `Idempotency-Key` sampai ke layanan lewat CloudFront (**5 dari 5**, termasuk `Idempotent-Replay: true`) dan `uji_e2e.py` **10 dari 10** |
| Uji matikan PRIMARY poem-db dengan probe tulis | **s6** (poem-db-3 PRIMARY, poem-service, relay, consumer) di-Stop 17:28:19 UTC lewat CLI. PRIMARY pindah ke **poem-db-1** (sudah terbaca di pemeriksaan 17:30:01, yaitu paling lambat 102 detik sesudah Stop). Pemantau lewat ALB (1 GET per detik, 1 tulis berkunci tiap 5 detik) selama 17:27:49 sampai 17:35:49: **0 baris gagal**, tidak ada tulis yang perlu dikirim ulang. s6 dinyalakan 17:30:29; poem-db-3 kembali **ONLINE (SECONDARY)** sebelum 17:32:20 (kurang dari 2 menit); `hitung` 39 penuh. `verifikasi` sesudahnya: **e2e 10 dari 10** |
| Memori dengan model Piper termuat terus-menerus | Tersedia (MB) sebelum, lalu sesudah pembaruan: s7 216 lalu 179, s8 374 lalu 497, s9 339 lalu 401; swap: s7 296 lalu 402, s8 502 lalu 636, s9 387 lalu 733 MB. Worker suara kini di **s9** (catatan penempatan lama: s8); kontainernya 277 MiB. Server paling ketat: **s7 (179 MB tersedia)**. Tidak ada OOM dan tidak ada layanan mati. Memori tetap tipis; ukur lagi di bawah beban banyak pengguna |
| Galat di log (15 menit sesudah pembaruan) | `Too many connections`, `gone away`, `circuit ... open`, `Fatal`, `Uncaught`, `SQLSTATE`: **0** di poem-service, poem-relay, auth-service, search-service |
| Skrip `image` yang diperbaiki (`127.0.0.1`, registry tidak dipasang ulang) | **Belum dijalankan** (lihat pelajaran di atas) |
| Deploy dari nol dengan kode baru dalam satu kali jalan | **BELUM** |
| `search-consumer` 3 replika (opsional) | **BELUM**, bawaan tetap 1 |
| Beban banyak pengguna (batas `max_connections = 100` dengan koneksi persisten) | **BELUM**; hanya diuji dengan lalu lintas kecil. Tombol darurat tetap disiapkan di `override-9server.yaml` |

Cuplikan keluaran aslinya: [`docs/bukti-aws/log-cloudshell/uji-pison-23nov.txt`](bukti-aws/log-cloudshell/uji-pison-23nov.txt).

Sisa data uji di aplikasi: pemantau dan `ujibaru` membuat sekitar 200 puisi berjudul `Uji pantau ...` dan `Uji idempotensi ...` (akun `uji...`), selain puisi `Pagi di Ladang` dari `uji_e2e.py`. Hapus bila galeri harus bersih untuk demo.

Disarankan: sebelum dikirim sebagai "terbukti 100%" ke dosen atau tim lain, jalankan dokumen ini **dari nol di sesi lab baru** dan perbarui tabel di atas.

---

## 12. Peta berkas

| Berkas | Fungsi |
|---|---|
| [`deploy/aws/9server.sh`](../deploy/aws/9server.sh) | Pengendali utama: `luncurkan`, `swarm`, `kode`, `image`, `deploy`, `rabbit`, `gateway`, `verifikasi`, `cek`, `status`, `image2`, `stack2`, `pasang`, `cabut`, `memori`, `hitung`, `jalankan`, `ujibaru`, `hapus` (tag lewat `TAG` dan `GATEWAY_TAG`) |
| [`deploy/aws/uji-ketahanan-baru.py`](../deploy/aws/uji-ketahanan-baru.py) | Uji kode Pison: `idempotensi`, `throttle`, `semua`, `pantau` (probe tulis saat server dimatikan). Dijalankan di AWS 23 Nov 2026 |
| [`deploy/aws/alb.sh`](../deploy/aws/alb.sh) | ALB: `buat`, `status`, `hapus` |
| [`deploy/aws/cloudfront-dua-jalur.sh`](../deploy/aws/cloudfront-dua-jalur.sh) | CloudFront dua jalur: `buat`, `unggah`, `status`, `hapus` |
| [`deploy/aws/https-cloudfront.sh`](../deploy/aws/https-cloudfront.sh) | Cadangan: CloudFront satu asal ke ALB |
| [`deploy/aws/bangun6.sh`](../deploy/aws/bangun6.sh), [`bangun2.sh`](../deploy/aws/bangun2.sh) | Membangun 6 image tahap 1 dan 2 image tahap 2 |
| [`deploy/aws/override-9server.yaml`](../deploy/aws/override-9server.yaml) | Penyesuaian memori untuk server 2 GiB (heap OpenSearch 384 MB, 1 worker suara, gateway `${GATEWAY_TAG}`) dan tombol darurat berkomentar untuk kode Pison (`DB_PERSISTEN`, `DB_PERSISTENT`, `TTS_ENGINE`) |
| [`deploy/swarm/stack.yaml`](../deploy/swarm/stack.yaml) | Definisi 38 layanan; [`stack.registry.yaml`](../deploy/swarm/stack.registry.yaml) registry sendiri |
| [`deploy/swarm/Dockerfile.gateway`](../deploy/swarm/Dockerfile.gateway), [`gateway/`](../deploy/swarm/gateway/) | Image gateway, konfigurasi IP klien, pembuat rentang IP CloudFront |
| [`deploy/lambda/`](../deploy/lambda/) | `siapkan-gambar.sh`, `buat-fungsi.sh`, dan README jalur manual |
| [`deploy/cek-sandbox.sh`](../deploy/cek-sandbox.sh), [`cek-launch.sh`](../deploy/cek-launch.sh) | Pemeriksaan sandbox (hanya membaca / `--dry-run`) |
| [`ARSITEKTUR-DEPLOY-AWS.md`](ARSITEKTUR-DEPLOY-AWS.md) | Arsitektur yang berjalan: batas instance, penempatan layanan, hubungan antar-server, ketahanan |
| [`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md) | Cerita eksperimen, keputusan, temuan, pengukuran, bukti |
| [`docs/bukti-aws/`](bukti-aws/) | Tangkapan layar (header berisi nomor akun sudah dipotong) dan log CloudShell |
