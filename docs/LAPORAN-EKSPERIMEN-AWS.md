# Laporan Eksperimen AWS Sandbox (23 November 2026, ditambah 24 dan 28 November 2026)

> **Pembaruan 28 November 2026:** arsitektur final dengan **Redis Sentinel** (43 layanan) dideploy **dari nol lewat GitHub** dan diuji di AWS. Ringkasannya di bagian 1,
> ceritanya di Fase 10, angkanya di bagian 3. Bagian lain yang menyebut "38 layanan" dan "Redis satu salinan" adalah keadaan 23 November.

Dokumen ini bercerita: **apa yang dicoba langsung di AWS, apa yang berhasil dan gagal, apa yang terukur, dan kenapa rancangan berubah** (dari "semua lewat ALB"
menjadi "CloudFront yang memecah jalur"). Ia **bukan** panduan langkah. Untuk men-deploy ulang, ikuti [`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md).

Semua angka diambil dari keluaran yang tampil di terminal AWS CloudShell hari itu (waktu UTC), bukan dari perkiraan. Yang tidak terbukti ditandai. Bukti ada di
[`docs/bukti-aws/`](bukti-aws/) (bagian 9). Eksperimen dikerjakan bersama Claude lewat Chrome dan CloudShell, di bawah pengawasan Ridlo.

---

## 1. Ringkasan: pertanyaan dan jawaban jujurnya

| Pertanyaan | Jawaban |
|---|---|
| Bisakah seluruh aplikasi (38 layanan) berjalan di sandbox? | **Ya**: 9 server `t3.small`, 39 layanan penuh (38 + registry), `uji_e2e.py` **10 dari 10**. Dicapai dua tahap: 23 layanan, lalu pencarian dan TTS ditambahkan |
| Dan versi final dengan Redis Sentinel (43 layanan)? | **Ya (28 Nov)**: 44 layanan penuh (43 + registry), `uji_e2e.py` **10 dari 10** dari dalam server, lewat ALB, dan lewat HTTPS CloudFront |
| Apakah Redis Sentinel bekerja di Swarm? | **Ya, untuk matinya satu layanan Redis (28 Nov)**: master di-scale ke 0, Sentinel memindahkan master dalam 9 detik, node lama kembali sebagai replika, aplikasi menulis ke master baru. **Juga per server**: saat s3 (pemegang master `redis-3`) dimatikan, master pindah ke `redis-1` |
| Tahan satu server mana pun mati (43 layanan)? | **Ya (28 Nov, s1 sampai s9 bergantian)**: 0 dari 1.076 kiriman puisi gagal; hanya beberapa `GET` gagal dalam 20 detik saat gateway (s1 sampai s3) mati; audio (s7) dan pencarian (s3) tertunda lalu menyusul; semua server kembali sendiri dalam 141 sampai 273 detik |
| Bisakah HTTPS? | **Ya, hanya lewat CloudFront.** ALB tidak bisa HTTPS di sandbox (ACM dan Route 53 tidak ada) |
| Apakah frontend bisa dilayani dari S3? | **Ya.** CloudFront dua jalur: halaman dari S3, `/api` dan `/audio` ke ALB, `/fungsi` ke Lambda. 8/8 uji skrip, e2e 10/10 dari luar |
| Tahan satu server mati? | **Terbukti dengan 23 layanan**: 0 dari 258 probe gagal saat s4 mati, PRIMARY database pindah otomatis, pulih ± 100 detik. **Belum dengan 38 layanan** |
| Bebas SPOF? | **Tidak.** SeaweedFS (audio) satu proses di satu server, registry satu salinan, worker suara satu replika, ALB masih terbuka lewat HTTP. (Redis satu salinan hanya sampai 24 Nov; sejak 28 Nov 3 node + 3 Sentinel) |
| Apakah deploy bisa diulang dari nol memakai dokumen? | **Ya.** 24 Nov dari nol dengan dua perbaikan manual kecil (catatan Ridlo); **28 Nov dari nol lewat GitHub memakai panduan apa adanya**, 30 menit sampai HTTPS lulus, tanpa perbaikan manual |

---

## 2. Kronologi eksperimen

### Fase 0: memeriksa sandbox, sebelum membuat apa pun
Dua skrip yang **hanya membaca** (`deploy/cek-sandbox.sh`, `deploy/cek-launch.sh`, dengan penyaring privasi) dijalankan di CloudShell. Temuannya mengubah semua rencana awal
(rencana awal: belasan server `t3.large`, Ubuntu, ECR):

- `t3.large` dan `t3.medium` **ditolak** (`explicit deny`, pernyataan `Ec2RestrictInstanceTypes`); hanya `t2/t3` sampai `small`.
- **9 instance sekaligus menurut Readme lab** (belum diuji saat itu; lihat koreksi di bawah), AMI harus milik Amazon (dipakai Amazon Linux 2023), EBS ≤ 35 GB, ECS/EKS/EFS tidak ada, IAM tidak bisa membuat role (ada `LabRole`).
- Pesan galat AWS **membocorkan nomor akun dan email**. Sejak itu semua skrip menyaring keluarannya (`bersih()`), diuji dengan data bocoran palsu.

### Fase 0b: bagaimana Claude bisa mengakses AWS
Awalnya Claude tidak punya akses AWS. Yang dicoba dan hasilnya: peramban Brave **tidak didukung** ekstensi; panel browser bawaan aplikasi memblokir tab baru dari input Claude;
terminal tertanam di halaman lab tidak menerima ketikan sintetis. **Yang berhasil:** ekstensi **Claude in Chrome di Google Chrome**, lalu **AWS CloudShell** sebagai terminal
(kredensial sudah terisi). Berkas dikirim lewat Actions → Upload file, satu per satu. Server dikendalikan lewat **SSM** (`send-command`), tanpa kunci SSH.

### Fase 1: keputusan 9 server
Ridlo meminta "banyak server karena harus scalable", lalu memilih memakai **9 instance**, angka di aturan lab (`t3.small`, 2 GiB). **Diuji 23 Nov sore (tiga kali):** API EC2 **menerima** peluncuran sampai total 38 instance, tetapi **sistem lab menghentikan kelebihan di atas 9 dalam ± 10 detik**, juga di `us-west-2`. Jadi 9 adalah batas efektif per akun; analisis lengkap dan bukti di [`ARSITEKTUR-DEPLOY-AWS.md`](ARSITEKTUR-DEPLOY-AWS.md) bagian 2. Susunan: s1 sampai s3 infra, s4 sampai s6 puisi + genre,
s7 sampai s9 auth, tersebar di zona a, b, c; tiga manager Swarm (s1, s2, s3).

### Fase 2: tahap 1, 23 layanan
`luncurkan` (9 server Running ± 2 menit), `swarm` (± 8 menit), `image` (6 image dalam **2 m 47 d**), `deploy` (23 layanan penuh ± 4 menit). Pencarian dan TTS **sengaja dibuang** dari deploy
karena perkiraan memori saat itu menyatakan tidak muat (perkiraan ini kemudian terbukti terlalu pesimis, fase 6). Hasil: `uji_e2e.py` 8/10 (`audio` dan `pencarian` belum ada).
Dua hal ditemukan: RabbitMQ tidak berklaster (bagian 5) dan pemeriksaan `grep -q active` yang juga cocok dengan "inactive".

### Fase 3: ALB, lalu Lambda + S3 + CloudFront
`alb.sh buat` (± 4 menit, 3 target `healthy`). `siapkan-gambar.sh` membuat bucket S3 publik, fungsi Lambda `nodejs24.x` + Function URL, latar, dan distribusi CloudFront dalam sekali jalan:
**2 dari 2 uji**. Ridlo membuka alamat akar distribusi itu dan melihat `NoSuchKey`: itu **normal** (bucket hanya berisi `latar*.jpeg`), tetapi memunculkan pertanyaan "kenapa aplikasi tidak di CloudFront?",
yang menjadi bahan fase 7.

### Fase 4: HTTPS, rancangan A (CloudFront → ALB)
`https-cloudfront.sh`: satu distribusi, asal ALB (HTTP), semua path lewat sana tanpa cache. **4 dari 4 uji** (halaman 200; `/api/puisi/sehat` 200; `http://` 301; `POST /api/auth/login` 401 dari aplikasi).
Distribusi `Deployed` dalam < 5 menit.

### Fase 5: uji matikan server (23 layanan)
Pemantau menembak ALB 1 kali per detik, **508 probe** (13:08:49 sampai 13:17:29).

| Kejadian | Waktu | Hasil |
|---|---|---|
| Server 4 (PRIMARY poem-db-1, 1 dari 3 poem-service) di-**Stop** lewat EC2 | 13:09:21 | **0 probe gagal** selama mati |
| Primary poem-db | otomatis | `poem-db-3` menjadi PRIMARY; Swarm menandai node `Down` |
| Uji tulis saat mati: register, login, **kirim puisi (202)**, baca puisi ke-2 | 13:11:26 sampai 13:12:33 | 8/10 lulus; **tidak ada data hilang** |
| Server 4 dinyalakan | 13:13:46 | 13:15:27: 9 node `Ready`, semua layanan penuh, `poem-db-1` bergabung kembali (3 ONLINE), ± 100 detik |
| Rolling update gateway (image `CDN_URL`) | 13:16:27 | **2 probe gagal (502)**, keduanya saat penggantian task gateway |

**Batas uji ini (jujur):**
- 258 probe diukur dari log antara penanda STOP (13:09:21) dan START (13:13:46) dengan `awk`. (Angka "sekitar 270" yang sempat saya tulis salah; yang terukur 258.)
- Probe `GET /api/puisi` (bisa dilayani dari cache gateway) dan `GET /healthz`, lewat gateway di s1 sampai s3. **s4 tidak menjalankan gateway**: yang dibuktikan ketahanan layanan di belakangnya, bukan pintu masuknya.
- **Uji tulis dijalankan ± 2 menit setelah server dimatikan**, bukan di detik perpindahan PRIMARY. Jadi tidak terbukti penulisan lolos tepat saat failover; yang terbukti: setelah PRIMARY pindah, penulisan berhasil dan tidak ada puisi hilang.
- 502 terjadi saat rolling update, **bukan** saat server dimatikan; dugaan: task gateway lama dihentikan sebelum ALB menandainya tidak sehat. Perbaikan yang masuk akal (`start-first` + healthcheck) **belum diuji**.
- Satu server, satu kali; belum diulang.

### Fase 6: tahap 2, pencarian dan text-to-speech (menjadi 38 layanan)
Ridlo bertanya kenapa pencarian menampilkan "layanan tidak tersedia" dan di mana TTS. Jawabannya: kodenya lengkap tetapi **sengaja belum dipasang** (fase 2). Pada pengukuran memori diam, perkiraan awal terlalu pesimis, jadi
dicoba dipasang bertahap di atas sistem yang berjalan (OpenSearch di s1 sampai s3, TTS di s7 sampai s9), dengan `override-9server.yaml` (heap OpenSearch 384 MB, agen *performance analyzer* dimatikan, 1 worker suara).
Jalan yang dilalui:

1. **Kode terbaru**: hanya 9 berkas PR #6 (`git diff --name-only 18f4331 6eee96a`) yang dikirim, **bukan arsip penuh**: berkas yang dipakai Swarm config/secret tidak boleh berubah isinya.
2. **Image**: `puisi-pencarian` 21 d, `puisi-tts` 1 m 47 d. `stack deploy` dengan override: layanan baru `0/1` menunggu label; task layanan lama **tidak ada yang diganti**.
3. **OpenSearch buntu**: setelah label dipasang dan `vm.max_map_count` diatur, tiga node `0/1` selama ± 9 menit, log `UnknownHostException: opensearch-2`. Penyebab dibuktikan dari dalam container (nama node 2 dan 3 tidak terselesaikan).
4. **Upaya perbaikan pertama gagal**: healthcheck diganti lewat berkas override, tetapi `docker service inspect` menunjukkan dua perintah berurutan (yang lama tetap berjalan). `stack deploy` **menambahkan** daftar `test`.
5. **Perbaikan yang berhasil**: ubah `deploy/swarm/stack.yaml` langsung. Sebelum mengirimnya, dipastikan `stack.yaml` lokal identik dengan yang di server (checksum sama). Klaster **hijau**, 3 node, 0 shard tak terpasang.
6. **TTS**: label dipasang, tetapi layanan tetap `Pending` ("no suitable node") 25 menit walau label benar; `service update --force` menjadwalkannya. tts-db 3 ONLINE, `uji_e2e.py` **10 dari 10**.
7. **Hitungan akhir** menunjukkan 1 layanan belum penuh: `tts-db-router` 1 dari 2 (replika kedua `Pending` 42 menit). Diperbaiki dengan `docker service scale` turun lalu naik. Setelahnya **39 layanan penuh, 0 belum**.

### Fase 7: rancangan B, CloudFront dua jalur
Setelah membandingkan tiga cara mengakses aplikasi (bagian 4), Ridlo memilih **CloudFront yang memecah jalur**. Dibuat `cloudfront-dua-jalur.sh`: asal S3 website (halaman), ALB (`/api/*`, `/audio/*`), Lambda (`/fungsi*`).
`web/js/api.js` **tidak diubah**: skrip menyisipkan alamat distribusi ke salinan yang diunggah. Hasil: **8 dari 8** uji skrip; dari browser Chrome (satu asal HTTPS): `/api/puisi` 200, `/api/search?q=pinang` 200, gambar kutipan 200 `image/jpeg`;
**`uji_e2e.py` lewat alamat CloudFront 10 dari 10**; header `x-cache`: berkas statis `Hit from cloudfront`, `/api/puisi` `Miss` (diteruskan ke ALB). Distribusi dibuat dan `Deployed` dalam ± 8 menit.
Sebagai bagian rancangan ini, gateway dibangun ulang sebagai **v3** dengan rentang IP CloudFront (bagian 5): tiga task `v3`, IP yang dicatat gateway sama dengan IP pengunjung.

### Fase 8: pengujian ulang skrip dan dokumentasi
Dokumen deploy dipecah menjadi panduan dan laporan ini. Skrip final dikirim dan sebagian dijalankan ulang di sistem yang berjalan (rincian di `PANDUAN-DEPLOY-AWS.md` bagian 11): `hitung` benar, `cloudfront-dua-jalur.sh` 8/8 tanpa peringatan, `verifikasi` 10/10.
Dua kesalahan ditemukan dan diperbaiki saat itu (bagian 5): akhir baris CRLF dan pola pemeriksaan yang salah.

### Fase 9 (23 dan 24 Nov): kode Pison, lalu deploy ulang dari nol
Malam 23 Nov sistem yang berjalan diperbarui di tempat ke kode Bab 10 dan 11 (Pison): `ujibaru` 9 dari 9, uji matikan s6 dengan probe tulis 0 gagal. Pada 24 Nov Ridlo menjalankan panduan
dari nol (`git clone` di CloudShell, kode tetap dikirim lewat bucket): lulus dengan dua perbaikan manual (`rabbit` sempat `noconnection`; `q.tap` hanya 2 anggota). Rincian di `PANDUAN-DEPLOY-AWS.md` bagian 11b.

### Fase 10 (28 Nov): arsitektur final dengan Redis Sentinel, dari nol lewat GitHub
Revisi Hands On 3 mengganti Redis tunggal dengan `redis-1..3` dan `redis-sentinel-1..3` (`redis/mulai.sh`), yang di Swarm baru diuji sintaksnya. Versi Single (1 server) yang masih menyala
dihapus lebih dulu (batas 9 instance berlaku untuk seluruh akun), lalu dicek 0 semua. Skrip diubah sebelum menyentuh AWS: server 1 `git clone` cabang yang sama (tanpa bucket kode),
satu bucket dan satu CloudFront seperti versi Single, pemeriksaan Redis Sentinel (`redis`, `ujiredis`) dan anggota antrean quorum (`kuorum`). Cabang `ridlo/scalable-9server` (commit `82c0dea`) di-push,
lalu panduan dijalankan apa adanya dari 12:47 sampai 13:24 UTC. Semua langkah lulus tanpa perbaikan manual: 29 layanan di tahap 1, 44 di tahap 2, e2e 10 dari 10 di tiga jalur, CloudFront 8 dari 8,
failover Redis 9 detik, `ujibaru` 9 dari 9. Dua hal baru tercatat (bagian 5): Sentinel di s1 masuk TILT saat image dibangun di s1, dan satu baris `ujibaru` mencetak 0 yang tidak cocok dengan pemeriksaan langsung.
Resource dibiarkan menyala atas pilihan Ridlo. Cuplikan keluaran: [`deploy-9server-sentinel-28nov.txt`](bukti-aws/log-cloudshell/deploy-9server-sentinel-28nov.txt).

---

## 3. Hasil terukur

### 3.1 Waktu per langkah
| Langkah | 23 Nov | 28 Nov (Redis Sentinel, dari nol lewat GitHub) |
|---|---|---|
| 9 server Running | ± 2 menit | ± 1 menit |
| Swarm terbentuk (SSM, Docker, 3 manager, 6 worker, label) | ± 8 menit | 3,5 menit |
| Kode ke server 1 | (arsip lewat bucket) | `git clone` 7 detik |
| 6 image tahap 1 | 2 m 47 d (+ ± 4 menit pertama menarik image registry) | 2 m 44 d (registry siap dalam detik) |
| Tahap 1 penuh | 23 layanan, ± 4 menit | 28 layanan; dicek 3,5 menit sesudah `deploy`, sudah penuh |
| ALB, 3 target `healthy` | ± 4 menit | dicek ± 3,5 menit sesudahnya, sudah `healthy` |
| Lambda + S3 (+ CloudFront gambar pada 23 Nov) | < 10 menit | < 1 menit (tanpa CloudFront gambar) |
| `puisi-pencarian` / `puisi-tts` | 21 d / 1 m 47 d | 1 m 25 d / 1 m 45 d |
| Klaster OpenSearch hijau (setelah healthcheck diperbaiki) | ± 2 menit | (tidak diukur terpisah) |
| Tahap 2 penuh | 39 dengan registry | **44 dengan registry**, dicek 3 menit sesudah `pasang tts` |
| CloudFront dua jalur sampai `Deployed` dan teruji | ± 8 menit | 3 m 14 d |
| Dari `luncurkan` sampai e2e lewat HTTPS lulus | (tidak dalam satu jalan) | **30 menit** |
| Pemulihan server yang di-Stop lalu di-Start | ± 100 detik | (tidak diuji 28 Nov) |
| Failover Redis (master di-scale ke 0 sampai `switch-master`) | (belum ada Sentinel) | **9 detik**; node lama menjadi replika 13 detik sesudah dinyalakan |

### 3.2 Memori (total tiap server 1909 MB)
| Server | Isi | 23 layanan (diam) | 38 layanan (sesudah satu e2e) |
|---|---|---|---|
| s1 sampai s3 | infra (+ OpenSearch) | terpakai 502 sampai 538 MB | terpakai 1154 sampai 1195, **tersedia 524 sampai 568**, swap 58 sampai 124 |
| s4 sampai s6 | puisi + genre | 1012 sampai 1066 MB | 1130 sampai 1212, tersedia 516 sampai 629, swap 0 sampai 4 |
| s7 sampai s9 | auth (+ tts) | 929 sampai 1006 MB | 1324 sampai 1491, **tersedia 267 sampai 426**, swap 162 sampai 397 |

Perkiraan lama "satu node MySQL ≈ 0,9 GiB" ternyata terlalu tinggi. **s7 sampai s9 paling ketat.** Diukur diam, bukan di bawah beban banyak pengguna.

**28 Nov (43 layanan, sesudah empat e2e, failover Redis, dan `ujibaru`):** s1 sampai s3 terpakai 1198 sampai 1254 MB, **tersedia 457 sampai 524**, swap 43 sampai 106;
s4 sampai s6 terpakai 1106 sampai 1133, tersedia 589 sampai 621, swap 0 sampai 3; s7 sampai s9 terpakai 1329 sampai 1548, **tersedia 212 sampai 417**, swap 79 sampai 588.
Tiga node Redis dan tiga Sentinel tidak membuat s1 sampai s3 kehabisan memori. Paling ketat s8 (212 MB tersedia) dan s7 (swap 588 MB; worker suara 315 MiB ada di s7).

### 3.3 Uji ujung ke ujung (`scripts/uji_e2e.py`)
8/10 (23 layanan) → **10/10** (38 layanan; juga dari luar lewat HTTPS CloudFront). Audio: `GET /audio/puisi_N.mp3 -> 200`. Daftar `GET /api/puisi` memuat `url_audio` untuk kelima puisi yang ada, termasuk tiga yang lama
(3 pesan yang menunggu di antrean `q.text-to-speech` ikut diproses). **Pemutar audio di layar belum saya lihat** (tidak login lewat browser): caranya di `PANDUAN-DEPLOY-AWS.md` bagian 6.
Puisi lama tidak terindeks di pencarian (9 pesan di `q.pencarian-indeks.dlq`).

28 Nov: 8/10 sesudah tahap 1, lalu **10/10** sebanyak empat kali: dari dalam server 1, dari CloudShell lewat ALB (HTTP), dari CloudShell lewat HTTPS CloudFront, dan dari dalam server 1 sesudah failover Redis.

---

## 4. Keputusan desain dan alasannya

### 4.1 Tiga cara mengakses aplikasi
| Cara | Alur | Kelebihan | Kekurangan |
|---|---|---|---|
| 1. Langsung ALB | browser → ALB → gateway | paling sederhana | hanya HTTP |
| 2. CloudFront → ALB (rancangan A) | browser → CloudFront (HTTPS) → ALB → gateway | HTTPS, perubahan kecil | halaman, JS, dan CSS tetap diambil dari server |
| 3. **CloudFront dua jalur (rancangan B, dipilih)** | halaman dari S3; `/api` dan `/audio` ke ALB; `/fungsi` ke Lambda | berkas statis di-cache edge, **server hanya mengurus API**; paling mendekati tujuan "scalable" | lebih banyak pekerjaan; frontend diunggah terpisah dari image gateway |

CloudFront bukan "terbaik untuk semua keadaan": di akun AWS biasa, ALB dengan sertifikat ACM sudah cukup untuk satu region. Di sandbox ini CloudFront adalah satu-satunya jalan ke HTTPS.

### 4.2 Lainnya
| Keputusan | Alasan |
|---|---|
| 9 server `t3.small` | batas sandbox |
| Registry sendiri di Swarm (bukan ECR) | ECR tidak diuji; registry sendiri terbukti bekerja |
| SSM, bukan SSH | tidak perlu mengelola kunci; CloudShell menjadi pusat kendali |
| Tahap 2 dipasang di atas tahap 1 yang berjalan | menghindari membangun ulang sistem; konsekuensinya urutan penuh dari nol belum dibuktikan satu kali jalan |
| Penyesuaian memori lewat **override**; perbaikan bug lewat **`stack.yaml`** | override menggabungkan daftar dengan menambahkan, jadi tidak bisa mengganti healthcheck; memori tidak termasuk bug |
| Heap OpenSearch 384 MB, agen *performance analyzer* mati, 1 worker suara, `search-service` 2 replika, `search-consumer` 1 | server manager hanya punya ± 1,1 GB tersedia |
| Rentang IP CloudFront dipercaya gateway (`01-cloudfront.conf`, dibuat otomatis) | tanpa itu batas login dihitung per edge, bukan per pengunjung |
| (28 Nov) Redis 3 node + 3 Sentinel, satu pasang per server infra, Sentinel memakai nama layanan Swarm | failover tanpa layanan terkelola; nama layanan Swarm adalah VIP yang tetap ter-resolve walau task mati, berbeda dengan Compose yang butuh IP tetap |
| (28 Nov) Server 1 `git clone`, satu bucket, satu CloudFront | lebih sedikit resource dan langkah, sama dengan versi Single |

---

## 5. Temuan, bug, dan koreksi atas klaim sendiri

| Temuan | Status |
|---|---|
| **RabbitMQ tidak otomatis berklaster di Swarm**: node 2 dan 3 menyala sebelum node 1 dan membentuk klaster sendiri; `docker service update --force` (catatan lama) tidak memperbaikinya | `9server.sh rabbit`: reset node 2 dan 3, `join_cluster`, `rabbitmq-queues grow`. Kini dengan penjaga (lewati node yang sudah anggota; tanpanya, menjalankannya di sistem berklaster mereset node 2 lalu 3 dan antrean quorum kehilangan mayoritas sesaat) |
| `grep -q active` juga cocok dengan "inactive" sehingga `swarm init` terlewat | Diperbaiki (`grep -qx active`) |
| Keluaran `image` tampak kosong beberapa menit | `\| tail` menahan keluaran dan registry ± 4 menit menarik image. Bukan galat |
| Pesan galat AWS membocorkan nomor akun dan email | `bersih()` di semua skrip. Sisa akhiran nomor akun di satu log bukti ditemukan dan dihapus |
| **OpenSearch buntu DNS**: healthcheck `/_cluster/health`; Swarm baru mendaftarkan nama DNS task yang sehat; klaster baru terbentuk bila node saling menerjemahkan nama | Diperbaiki di `stack.yaml` (healthcheck `GET /` saja; HAProxy tetap memeriksa klaster) |
| **`stack deploy -c a -c b` menambahkan daftar `test`**, tidak menggantinya | Perbaikan harus di `stack.yaml`, bukan override |
| **Layanan `Pending` tidak otomatis dijadwalkan** setelah label (TTS); replika kedua `tts-db-router` macet 42 menit walau `--force` | `service update --force`; untuk replika macet: `service scale` turun lalu naik. Kenapa hanya sebagian layanan terkena **belum dipahami**. Terungkap hanya karena `hitung` |
| Pemeriksaan "layanan lama berubah" lewat `Version.Index` menandai semua layanan | Nomor itu naik untuk semua layanan tiap `stack deploy`. Ukuran yang benar: task layanan lama yang baru dimulai |
| Pola pemeriksaan task baru `[1-5] minutes` cocok dengan "31 minutes" (positif palsu di pengujian ulang) | Pola kini diawali `Running ...`, diuji terhadap sembilan contoh di laptop; belum dijalankan ulang di AWS |
| Perintah tunggu dengan `curl` ke OpenSearch yang belum jadi menggantung 30 detik per percobaan | `curl -m 8` dan pemeriksaan singkat berulang |
| CloudShell: `Too Many Requests` untuk unggahan kedua berturut-turut; sesi putus dan lingkungan `SUSPENDED` bila diam lama; klik di baris tab menutup tab | Dicatat di panduan (bagian 3) |
| **Skrip disunting lewat Python di Windows tersimpan CRLF**; bash di CloudShell gagal `$'\r': command not found` | Gagal di awal sebelum perintah AWS berjalan. Dikembalikan ke LF. `.gitattributes` repo sudah memaksa LF untuk `*.sh`, `*.yaml`, `*.conf` agar kejadian ini tidak terulang di tim |
| Satu berkas tim yang dilacak git (`docs/FULL_IMPLEMENTATION_AND_TEST_REPORT.md`) ikut berubah akhir barisnya oleh perintah normalisasi yang terlalu luas | Dikembalikan dengan `git checkout`; tidak ada berkas terlacak yang berubah (`git status` bersih untuk berkas terlacak) |
| (24 Nov, Ridlo) `rabbit` sempat `noconnection`; `grow` tidak menambahkan rabbitmq-3 ke `q.tap` | Sejak 28 Nov `rabbit` melengkapi anggota antrean quorum sendiri (`kuorum perbaiki`). 28 Nov tidak terulang: 13 dari 13 |
| (28 Nov) **Sentinel masuk TILT saat server 1 membangun image**: 13:03 UTC, `image2` membangun `puisi-tts` di s1; `redis-sentinel-1` (s1) tiga kali `+tilt`, healthcheck tiga kali melewati batas 3 detik, Swarm menyalakannya ulang 13:04 (keluar 0, bukan OOM) | Master tidak berpindah, dua Sentinel lain normal. Dicatat di panduan bagian 9: jangan membangun image saat demo failover. Penyebab langsungnya: proses tersendat lebih dari sekitar 2 detik di server yang sibuk build |
| (28 Nov) Saat start, Sentinel mencatat `Failed to resolve hostname 'redis-sentinel-2'` selama ± 9 detik | Wajar: Swarm baru mendaftarkan nama task sesudah task berjalan. Hilang sendiri, tidak menyebabkan TILT |
| (28 Nov) `ujibaru` mencetak "tabel idempotensi 0" di ketiga node, padahal tabelnya ada | Pemeriksaan langsung menemukan tabel di poem-db-1, -2, -3, dan baris perintah yang sama dijalankan ulang mencetak `1`. **Penyebab belum dipastikan** |
| (28 Nov) Proses yang berjalan di depan di CloudShell hilang saat sesi berakhir karena "tidak ada interaksi" (saat menunggu hapus CloudFront versi Single) | Perintahnya kebetulan sudah selesai. Sejak itu semua perintah panjang dijalankan `nohup ... > log &` dan lognya diintip; dicatat di panduan bagian 3 |
| (28 Nov) Probe `GET /api/puisi` selama failover Redis (118, 0 gagal) bisa dijawab dari cache gateway | Tidak dipakai sebagai bukti Redis. Buktinya jalur tulis: `puisi:galeri:versi` di master baru naik 23 ke 28 dan e2e 10/10 sesudah failover |

**Koreksi atas klaim saya sendiri sepanjang eksperimen:** "maksimal 9 instance" ditulis sebagai "terbukti" padahal hanya bersumber dari Readme dan tidak diuji; setelah diuji, jawabannya bernuansa (API menerima, sistem lab menghentikan kelebihan dalam detik); sempat pula saya tulis (sebelum pengujian kedua) bahwa itu "hanya aturan, bukan batas yang ditegakkan", dan itu salah karena saya menghapus instance uji ke-10 terlalu cepat untuk melihat penegakannya; "tiga klaster MySQL" pada tahap 1 salah (dua: poem-db dan auth-db; tts-db menyusul di tahap 2); "sekitar 270 probe" salah (258); "pencarian dan TTS tidak muat" salah;
"pemutar audio hanya di kartu puisi baru" terlalu sempit (daftar memuat `url_audio` untuk semua puisi); sempat menulis bahwa log bukti tanpa akun/email, padahal satu log memuat akhiran nomor akun.

---

## 6. Perubahan kode dan berkas yang dibuat

Semua di `deploy/` dan `docs/`. **Berkas tim di `web/`, `gateway/`, `services/`, `workers/` tidak diubah.**

| Berkas | Perubahan |
|---|---|
| `deploy/swarm/stack.yaml` | healthcheck OpenSearch `GET /` (tiga tempat, dengan komentar alasannya); header status diperbarui |
| `deploy/swarm/Dockerfile.gateway` | `COPY deploy/swarm/gateway/*.conf` agar `01-cloudfront.conf` ikut bila ada |
| `deploy/swarm/gateway/buat-cloudfront-conf.sh` (baru) | membuat daftar `set_real_ip_from` rentang IP CloudFront (217 IPv4 + 35 IPv6) |
| `deploy/aws/9server.sh` | subperintah baru `image2`, `stack2`, `pasang`, `cabut`, `memori`, `hitung`; `kode <arsip>`; `gateway` membuat v3; `verifikasi` menunggu audio |
| `deploy/aws/bangun2.sh`, `override-9server.yaml`, `cloudfront-dua-jalur.sh` (baru) | tahap 2 dan CloudFront dua jalur |
| `deploy/aws/alb.sh`, `https-cloudfront.sh`, `bangun6.sh`, `deploy/lambda/*`, `deploy/cek-*.sh` | tahap 1 dan pemeriksaan sandbox |
| (28 Nov) `deploy/aws/9server.sh` | `kode` tanpa argumen: server 1 `git clone`; user-data memasang git; subperintah baru `gambar`, `cloudfront`, `kuorum`, `redis`, `ujiredis`; `gateway` menerima `CDN_URL` kosong; jumlah layanan 43 |
| (28 Nov) `deploy/aws/uji-redis-sentinel.sh` (baru) | uji failover Redis Sentinel di Swarm, dijalankan di server 1 |
| (revisi Hands On 3, sebelum 28 Nov) `deploy/swarm/stack.yaml`, `redis/mulai.sh` | Redis 3 node + 3 Sentinel; diuji di AWS 28 Nov |

---

## 7. Yang belum dibuktikan, dan skenario uji lanjutan

**Sudah (28 Nov):** uji matikan server s1 sampai s9 bergantian dengan 43 layanan, termasuk failover Redis karena server (s3) mati. **Belum dibuktikan:** dua server mati bersamaan, satu zona mati; memori di bawah beban banyak pengguna (stress test menunggu keputusan tim); pemutar audio di layar; `start-first` untuk menghilangkan 502 saat rolling update; ECR; observability, k6, CI;
scale-out (tidak ada server ke-10). Deploy ulang dari nol dalam satu kali jalan **sudah** (24 dan 28 Nov).

**Skenario uji lanjutan** (dijalankan **satu per satu**, pulihkan penuh dan jalankan `hitung` serta `verifikasi` sebelum yang berikutnya; matikan dengan **Stop**, bukan Terminate):

| # | Skenario | Cara | Harus tetap | Diperkirakan | Status |
|---|---|---|---|---|---|
| S1 | s4 mati (PRIMARY poem-db, 1 dari 3 poem-service) | Stop s4 | semuanya | 0 probe gagal | **Dijalankan (23 layanan)** |
| S2 | s7 mati (SeaweedFS, tts-db-1, auth-db-1) | Stop s7 | semua kecuali **audio** | audio berhenti: SPOF yang diketahui | **Dijalankan 28 Nov**: sesuai prediksi; audio menyusul sesudah s7 hidup; 0 tulis gagal |
| S3 | s1 mati (manager, gateway, RabbitMQ-1, OpenSearch-1, sejak 28 Nov juga redis-1 dan redis-sentinel-1) | Stop s1 | semuanya lewat ALB (gateway di s2 dan s3); bila redis-1 master, Sentinel di s2 dan s3 memilih master baru | ± 20 detik sampai ALB menandai tidak sehat | **Dijalankan 28 Nov**: e2e 10/10; 6 GET gagal dalam 20 detik pertama; 0 tulis gagal |
| S1b sampai S3b | setiap server lain (s2 sampai s6, s8, s9) | `bash ~/9server.sh matikan semua` | semuanya | | **Dijalankan 28 Nov**: lihat `PANDUAN-DEPLOY-AWS.md` bagian 11a |
| S10 | master Redis mati (layanan saja) | `bash ~/9server.sh ujiredis` | aplikasi menulis ke master baru | failover dalam detik | **Dijalankan 28 Nov**: 9 detik, node lama kembali replika, e2e 10/10 sesudahnya |
| S4 | satu node OpenSearch mati | Stop s2 | pencarian (hijau → kuning → pulih) | jeda singkat | belum |
| S5 | satu zona mati (s1, s4, s7) | Stop tiga server | diperkirakan tetap jalan, audio tidak | beberapa PRIMARY pindah bersamaan | belum |
| S6 | gateway di satu server di-`docker kill` | `docker kill $(docker ps -q -f name=puisi_gateway)` di s1 | semuanya | waktu Swarm menyalakan ulang | belum |
| S7 | rolling update gateway dengan `start-first` | `update_config: order: start-first` | 0 probe gagal | menghilangkan 502 | belum |
| S8 | mati total lalu hidup | Stop semua, Start | pulih lewat job `*-cluster-init` | waktu pemulihan | belum |
| S9 | (opsional) dua server dari klaster data yang sama (s4 dan s5) | Stop dua | layanan lain jalan | **penulisan puisi gagal** (kuorum hilang): batas, bukan kegagalan uji | belum |

**Yang dicatat tiap skenario:** detik sampai pemantau pertama gagal; detik sampai pulih untuk rute "harus tetap"; rute **di luar prediksi** yang ikut gagal (temuan terpenting); apakah PRIMARY pindah otomatis; apakah ada puisi `202` yang hilang
(bandingkan jumlah puisi sebelum dan sesudah); memori server yang hidup; apakah node, klaster MySQL, dan klaster RabbitMQ pulih sendiri setelah server dinyalakan.
**Penerimaan (S1 sampai S4):** setiap rute "harus tetap" kembali menjawab 200 atau 202 dalam 60 detik sejak server dimatikan dan tidak ada puisi `202` yang hilang. Rute "diperkirakan berhenti" yang berhenti sesuai prediksi dilaporkan
sebagai **SPOF tersisa**, bukan kegagalan.

---

## 8. Kalimat laporan yang bisa dipertanggungjawabkan

> "Seluruh aplikasi (38 layanan) berjalan di 9 server `t3.small` dalam 3 zona dengan Docker Swarm; `uji_e2e.py` lulus 10 dari 10, juga dari luar lewat HTTPS CloudFront yang memecah jalur
> (halaman dari S3, API lewat ALB, gambar dari Lambda). Pada konfigurasi 23 layanan, saat satu server pemegang PRIMARY database dimatikan, 0 dari 258 probe lewat ALB gagal, PRIMARY berpindah otomatis, penulisan tetap berhasil,
> dan server pulih dalam ± 100 detik. Dua dari 508 probe gagal saat rolling update gateway."

Untuk versi final (28 Nov):

> "Versi final (43 layanan, termasuk Redis 3 node dengan 3 Sentinel) dideploy dari nol dengan kode dari GitHub dalam 30 menit dan lulus `uji_e2e.py` 10 dari 10 lewat HTTPS CloudFront.
> Saat layanan master Redis dimatikan, Sentinel memilih master baru dalam 9 detik, node lama kembali sebagai replika, dan aplikasi tetap menulis ke master baru."

> "Kesembilan server dimatikan bergantian satu per satu. Tidak ada satu pun dari 1.076 kiriman puisi yang hilang, database dan Redis memindahkan PRIMARY/master sendiri, dan setiap server
> kembali bergabung sendiri dalam 2 sampai 5 menit. Yang terasa pengguna hanya beberapa galat dalam 20 detik saat server gateway mati, serta audio yang tertunda saat server penyimpanan audio mati."

**Jangan menulis "bebas SPOF"**: SeaweedFS (audio) satu proses, registry satu salinan, dua server mati bersamaan dan satu zona mati belum diuji.

---

## 9. Indeks bukti ([`docs/bukti-aws/`](bukti-aws/))

Tangkapan layar (header AWS yang memuat nomor akun sudah dipotong):

| Berkas | Isi |
|---|---|
| `01-semua-layanan-penuh.png`, `02-memori-9-server.png` | tahap 1: layanan penuh dan memori |
| `03-rabbitmq-3-node-antrean-quorum.png`, `13-rabbit-aman-diulang.png` | klaster RabbitMQ dan jalur "lewati" |
| `04-verifikasi-klaster-dan-e2e-8-dari-10.png` | verifikasi tahap 1 |
| `05-aplikasi-lewat-alb.jpg`, `15-aplikasi-lewat-https-cloudfront.jpg` | aplikasi di browser |
| `06-...`, `07-skrip-lambda-s3-cloudfront-berhasil.png` | gambar kutipan lewat CloudFront dan skrip Lambda |
| `08` sampai `12` | uji matikan server: PRIMARY pindah, uji tulis, server pulih, 258 probe, ringkasan 508 probe |
| `14-https-cloudfront-di-depan-alb-4-dari-4.png` | rancangan A |
| `16-opensearch-nama-node-tidak-terselesaikan.jpg` | kebuntuan DNS OpenSearch |
| `17-healthcheck-digabung-bukan-diganti.jpg` | `stack deploy` menambahkan daftar healthcheck |
| `18-opensearch-hijau-3-node.jpg`, `19-tts-db-klaster-3-online.jpg` | tahap 2 berhasil |
| `20-e2e-10-dari-10.jpg`, `21-memori-9-server-38-layanan.jpg` | uji ujung ke ujung dan memori (38 layanan) |
| `22-cloudfront-dua-jalur-8-dari-8.jpg`, `24-e2e-lewat-cloudfront-10-dari-10.jpg` | rancangan B |
| `23-gateway-v3-ip-pengunjung-terbaca.jpg` | gateway v3 mencatat IP pengunjung |
| `25-semua-layanan-penuh-38-ditambah-registry.jpg` | hitungan akhir: 39 penuh, 0 belum |
| `26-percobaan-instance-ke-10-berhasil-dibuat.jpg` | AWS menerima instance ke-10 (saya hapus segera) |
| `27-uji-batas-region-dihentikan-9-detik.jpg` | instance di `us-west-2` dihentikan sistem lab 9 detik setelah peluncuran |
| `28-aplikasi-9server-sentinel-lewat-https-28nov.jpg` | (28 Nov) halaman aplikasi versi final lewat HTTPS CloudFront |

Log CloudShell di [`log-cloudshell/`](bukti-aws/log-cloudshell/): `swarm.log` (pembentukan Swarm), `cek.log` (keadaan layanan), `verifikasi.log`, `lambda.log` (skrip gambar; akhiran nomor akun sudah dihapus),
`mon.log` (pemantau 508 probe), `saat-mati.txt` (probe saat server dimatikan), `uji-instance-ke-10.log`, `uji-batas-instance.log`, `uji-batas-pelaku.log`, `uji-batas-region.log`, `uji-tipe-instance.log`, `analisis-batas.log` (batas EC2), `penempatan-layanan.txt` (penempatan sebenarnya), `uji-pison-23nov.txt` (kode Pison), `deploy-9server-sentinel-28nov.txt` (28 Nov: deploy dari nol, Redis Sentinel, failover, TILT, memori).
