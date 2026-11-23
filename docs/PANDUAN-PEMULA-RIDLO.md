# Panduan Pemula untuk Ridlo: Status Tugas, Konsep, dan Cara Menyambungkan Layanan

Dokumen ini ditulis untuk orang yang **belum paham sama sekali** soal microservice dan message broker.
Semua istilah dijelaskan dari awal. Tanggal pemeriksaan: **23 November 2026**.

Dokumen pendamping:
- [`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md): panduan deploy ke AWS (9 server) dari nol sampai HTTPS.
- [`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md): apa yang terukur di AWS, temuan, dan bukti.
- [`AUDIT-SPOF-DAN-SKALABILITAS.md`](AUDIT-SPOF-DAN-SKALABILITAS.md): komponen mana yang masih tunggal dan jalan menuju bebas SPOF.

## Daftar isi

1. [Jawaban singkat](#1-jawaban-singkat)
2. [Status tugas Ridlo](#2-status-tugas-ridlo)
3. [Konsep dasar dari nol](#3-konsep-dasar-dari-nol)
4. [Bagaimana semua layanan tersambung](#4-bagaimana-semua-layanan-tersambung)
5. [Menjalankan di laptop (Windows)](#5-menjalankan-di-laptop-windows)
6. [Masalah yang sering muncul](#6-masalah-yang-sering-muncul)
7. [Urutan kerja bersama teman](#7-urutan-kerja-bersama-teman)
8. [Daftar istilah](#8-daftar-istilah)

---

## 1. Jawaban singkat

**Apakah tugas Ridlo sudah selesai?**
**Ya, untuk isi tugasnya.** R1 sampai R4 sudah ada di `main` dan terbukti berjalan nyata di laptop Anda:
`uji_e2e.py` lulus **8 dari 10** tahap (dua sisanya, audio dan pencarian, milik teman dan belum bisa saya
nyalakan), uji anti-SPOF bagian Ridlo lulus **6 dari 6** skenario, dan galeri tampil benar di browser.
Bug galeri yang saya temukan (chip emosi) **milik Ridlo dan sudah diperbaiki** (bagian 2.4), tetapi
**belum di-commit**.

**Kalau sudah selesai, tinggal tes deploy?**
Hampir. Sisanya: commit perbaikan galeri, pastikan teman-teman memasukkan kodenya ke `main`, lalu
deploy. Tetapi pahami apa yang dibuktikan deploy satu server: bahwa semuanya **berjalan dan tersambung**,
**bukan** bahwa sistem bebas SPOF (lihat dua pertanyaan di bawah).

**Apakah semua microservice sudah terbukti tersambung?**
**Sebagian.** Tiga kelompok:
- **Terbukti tersambung nyata:** gateway, auth, puisi, genre, auto-tagging, emosi, RabbitMQ 3 node,
  Redis, dan klaster database.
- **Belum terbukti:** pencarian (OpenSearch), Text-to-Speech, dan observability. Unduhan image di
  jaringan Anda saat ini hanya sekitar 0,35 MB per detik sehingga tidak sempat saya nyalakan. Konfigurasinya
  valid, tetapi belum dijalankan bersama. Server AWS yang unduhannya cepat adalah tempat yang tepat untuk
  menguji ketiganya.
- **Tidak tersambung sama sekali:** worker `gambar-kutipan` (Ray) punya kode di `workers/gambar-kutipan/`
  tetapi **tidak ada layanan Compose-nya dan tidak ada antrean `q.gambar-kutipan`** di
  `rabbitmq/definitions.json`, jadi tidak pernah berjalan. Layanan gambar Lambda/CloudFront dari Hands-on 1
  juga tidak terhubung karena `KONFIG.cdn` di `web/js/api.js` kosong (mode lokal). Kartu puisi tetap
  tampil tanpa gambar. Kode galeri dan poem-service sudah siap menerima hasilnya bila nanti dipasang.

**Apakah sistem sudah scalable dan bebas SPOF?**
- **Scalable: ya untuk bagian puisi.** Saya menambah replika `poem-service` dari 2 menjadi 4 dengan satu
  perintah, dan gateway otomatis membagi 80 permintaan ke keempatnya tanpa mengubah konfigurasi.
- **Bebas SPOF: belum seluruhnya.** Bagian Ridlo tahan gagal: mati satu replika, satu router, Primary
  database, Redis, satu RabbitMQ, bahkan **semua** RabbitMQ, semuanya tetap melayani. Tetapi di seluruh
  sistem masih ada komponen **tunggal** (gateway, auth-db, tts-db, SeaweedFS, OpenSearch, Redis, dan lainnya),
  dan satu server AWS itu sendiri adalah satu titik gagal. Daftar lengkap dan jalan perbaikannya ada di
  [`AUDIT-SPOF-DAN-SKALABILITAS.md`](AUDIT-SPOF-DAN-SKALABILITAS.md).

**Apakah dua panduan ini sudah menjawab seluruh proyek?**
**Belum seluruhnya.** Panduan menjelaskan bagian Ridlo secara mendalam, alur antar layanan, cara
menjalankan, dan deploy satu server. Panduan **tidak** menjelaskan isi dalam layanan teman (auth,
pencarian, TTS, emosi, observability), dan jalur deploy bebas SPOF di banyak server **belum ada**
(hanya peta jalan di dokumen audit).

**Apakah saya dan teman harus sama-sama deploy?**
Tidak. **Cukup satu orang yang men-deploy** (yang memegang sandbox AWS). Teman-teman cukup memastikan
kodenya ada di `main`, lalu menguji tahap miliknya lewat alamat publik server itu. Rinciannya di bagian 7.

**Satu hal yang perlu dicek dulu:** file `tugas-dari-dosen.md` hanya menyebut output berupa
**dokumen rancangan arsitektur**. Deploy tidak disebut di sana. Tanyakan ke kelompok apakah demo deploy
diwajibkan atau hanya pelengkap. Kalau hanya pelengkap, deploy tetap berguna sebagai bukti, tetapi jangan
sampai menghabiskan waktu yang seharusnya untuk dokumen rancangan.

---

## 2. Status tugas Ridlo

### 2.1 Dua versi dokumen tugas

Anda punya dua versi dokumen tugas Ridlo, dan isinya **berbeda**:

| | File di Downloads | `Tugas-Ridlo.md` di repo (belum di-commit) |
|---|---|---|
| Database | `poem-db` biasa + satu replika GTID | **InnoDB Cluster 3 node + 2 MySQL Router** |
| Kunci cache Redis | `puisi:galeri:hal:{n}` | berversi: `puisi:galeri:v{versi}:hal:{n}` |
| Pengujian | uji biasa | ditambah `services/puisi/uji/uji_anti_spof.py` (6 skenario kegagalan) |

**Kode yang ada mengikuti versi repo (yang lebih baru).** Itu peningkatan, bukan kekurangan, tetapi
bila ada yang memeriksa memakai dokumen lama, mereka akan melihat perbedaan. Siapkan satu kalimat
penjelasan: "rancangan ditingkatkan menjadi Zero-SPOF sesuai matriks R10 di dokumen rancangan kelompok".

### 2.2 Isi R1 sampai R4 terhadap kode

Keterangan: ✅ terbukti saya jalankan hari ini, 📖 saya baca kodenya dan sesuai, ⏳ belum saya ulang hari ini.

**R1: layanan puisi, cek token, transactional outbox**

| Isi tugas | Status | Bukti |
|---|---|---|
| PHP 8.3 tanpa framework, router `/api/puisi` | ✅ | `services/puisi/public/index.php`, container berjalan PHP 8.3.36 |
| `Jwt.php` HS256, `hash_hmac`, `hash_equals`, cek `exp` | ✅ | PHPUnit lulus; vektor JWT cocok (`token_uji.py --periksa-vektor`) |
| Tabel `puisi` dan `outbox`, tanpa tabel users dan tanpa JOIN | ✅ | `services/puisi/db/init.sql`; penulis diambil dari klaim `nama` |
| `POST /api/puisi`: validasi, simpan puisi + outbox dalam satu transaksi, balas 202 | ✅ | 4 puisi uji dikirim lewat gateway, semuanya 202 dengan `id` |
| Tanpa token 401, judul kosong 400, pola `file_gambar` salah 400 | ✅ | diuji langsung lewat gateway |
| `bin/relay.php`: `SELECT FOR UPDATE SKIP LOCKED`, publisher confirm, tandai terkirim | ✅ | outbox **0 dari 67 baris belum terkirim**, ketiga node database punya 67 baris yang sama |
| `GET /api/puisi` dan `GET /api/puisi/{id}` | ✅ | diuji lewat gateway dan di browser |
| `compose/puisi.yaml`, `gateway/rute/puisi.conf` | ✅ | `docker compose config` valid, semua container `healthy` |

**R2: hasil analisis, cache Redis, replika**

| Isi tugas | Status | Bukti |
|---|---|---|
| `bin/consumer.php` menggabungkan hasil, idempoten | ✅ | puisi uji berubah dari `diproses` ke `sebagian` ke `selesai`; event yang sama dua kali menghasilkan keadaan identik |
| Kategori manual tidak tertimpa, kategori kosong terisi | ✅ | pemeriksaan logika lulus; puisi 63 mendapat kategori `alam` otomatis |
| Aturan ulang: `x-percobaan`, terbit ulang, lalu DLQ | 📖 | kode di `consumer.php`; `q.puisi-hasil.dlq` dan `q.klasifikasi-genre.dlq` masing-masing berisi 1 pesan dari uji sebelumnya |
| Cache-aside Redis, TTL 60 detik, dihapus saat data berubah | ✅ | header `X-Cache-Layer`: `db` lalu `redis` |
| Replika baca dengan fallback ke primary | ✅ | diganti klaster 3 node: setelah dipulihkan, 1 PRIMARY dan 2 SECONDARY `ONLINE`; router membaca topologinya |
| Nginx `proxy_cache` 10 detik, POST tidak di-cache | ✅ | `MISS` lalu `HIT`; kedaluwarsa menjadi `EXPIRED` dan jawaban dari `redis` |
| Redis dimatikan, galeri tetap terbaca | ✅ | `uji_anti_spof.py` skenario 4: `GET` 200 dengan `X-Cache-Layer: db` |
| Node database dimatikan, galeri tetap terbaca | ✅ | skenario 3: Primary `poem-db-1` dimatikan, failover ke `poem-db-3`, `POST` 202 dan `GET` 200 |

**R3: galeri dan form kirim**

| Isi tugas | Status | Bukti |
|---|---|---|
| `kirim.js` ke `POST /api/puisi`, kategori dan keyword opsional | 📖 | kode `web/js/kirim.js` |
| `galeri.js`: status, chip tag dan genre, pemutar audio, muat ulang tiap 5 detik | ✅ | di browser: 12 kartu dimuat dari API asli, **tanpa error di konsol** |
| Aman bila field belum ada | ✅ | kartu puisi tanpa analisis dibuat tanpa error |
| Chip **label emosi** | ✅ | bug ditemukan lalu **diperbaiki** (2.4); di browser kini tampil "Emosi: percaya (positif)" |

**R4: klasifikasi genre**

| Isi tugas | Status | Bukti |
|---|---|---|
| Bunyi akhir dan skema rima per bait | ✅ | unit test lulus |
| Aturan pantun / syair / gurindam / puisi bebas | ✅ | **empat jenis puisi dikirim lewat sistem sungguhan, keempatnya terklasifikasi benar** (pantun `abab`, syair `aaaa`, gurindam `aa aa`, bebas `aabc ab`) |
| Terbitkan `puisi.dianalisis` dengan sumber `klasifikasi-genre` | ✅ | hasilnya muncul di detail puisi |
| `rusak.json` ke DLQ, event ganda hasil identik | ✅ | unit test `test_gagal_ketiga_masuk_dlq` dan `test_event_sama_hasil_sama`; DLQ genre berisi 1 pesan |

### 2.3 Apa yang saya jalankan, dan apa yang belum

**Saya jalankan hari ini:**

| Pengujian | Hasil |
|---|---|
| Unit test worker genre dan kerangka worker (Python) | 32 tes, semua OK |
| PHPUnit di dalam container `poem-service` (PHP 8.3, sama seperti produksi) | 16 tes, 55 assertion, OK |
| Pemeriksaan logika JWT, validasi, penggabungan hasil (skrip sendiri, PHP lokal) | 19 pemeriksaan lulus |
| Uji lewat gateway dengan token uji: 401, 400, 202, detail, 4 genre, cache | 19 dari 20 pada percobaan pertama. Satu pemeriksaan (jawaban dari Redis setelah cache Nginx habis) gagal karena saya hanya menunggu 11 detik, padahal Nginx baru kedaluwarsa antara detik ke-11 dan ke-13. Saya ukur ulang terpisah: pada detik ke-13 statusnya `EXPIRED` dan lapisan `redis`, sesuai spesifikasi |
| Auto-tagging dinyalakan: puisi 63 menjadi `selesai` | status `selesai`, kategori `alam`, keyword terisi, genre `pantun` |
| Galeri di browser | 12 kartu, tanpa error konsol |
| `scripts/uji_e2e.py` resmi, dengan auth, auto-tagging, dan emosi menyala | **8 dari 10 tahap LULUS**: gateway, register, login, **submit**, **detail**, tag, **genre**, emosi. Tahap audio (Text-to-Speech) dan pencarian BELUM karena kedua layanan itu belum saya nyalakan |
| `services/puisi/uji/uji_anti_spof.py` resmi (6 skenario kegagalan) | **6 dari 6 LULUS**: satu `poem-service` mati, satu router database mati, Primary database mati (failover ke `poem-db-3`), Redis mati, satu RabbitMQ mati, dan **seluruh RabbitMQ mati lalu hidup lagi** (outbox menahan event dan terkirim setelah pulih). Setelah uji, klaster 3 node dan semua consumer pulih sehat |
| Menambah replika `poem-service` dari 2 menjadi 4 | `docker compose --profile puisi up -d --no-deps --scale poem-service=4 poem-service`: 80 dari 80 permintaan sukses, terbagi ke keempat replika (25, 13, 22, 20). Sudah dikembalikan ke 2 |
| Galeri di browser dengan data nyata dari worker | 12 kartu menampilkan "Status: selesai", "Genre: pantun (abab)", "Emosi: percaya (positif)", dan tag, tanpa `[object Object]` dan tanpa error konsol |

**Apakah yang diuji sama dengan kode terbaru?** Image `poem-service` dan `klasifikasi-genre` dibuat
8 November, sebelum commit terakhir. Karena itu saya membandingkan isi file di dalam container dengan
isi repo: semuanya identik, kecuali `public/.htaccess` (hanya beda akhir baris CRLF/LF) dan `genre.py`
(container kurang satu baris kosong di akhir file). Tidak ada perbedaan logika, jadi hasil di atas berlaku
untuk kode di `main`.

**Belum terbukti hari ini (jangan ditulis "sudah diuji" di laporan sebelum Anda menjalankannya sendiri):**

- Pembentukan klaster database dari disk **kosong**. Hari ini klaster hanya dipulihkan dari volume lama.
- Dua relay dengan 50 puisi, memastikan tiap puisi tepat satu event.
- **Pencarian (OpenSearch), Text-to-Speech, dan observability** tidak saya nyalakan karena unduhan image
  di jaringan ini hanya sekitar 0,35 MB per detik. Akibatnya tahap `audio` dan `pencarian` di
  `uji_e2e.py` masih BELUM.
- Kegagalan komponen yang memang tunggal: gateway, auth-db, tts-db, SeaweedFS, OpenSearch (lihat
  `AUDIT-SPOF-DAN-SKALABILITAS.md`).
- Matinya satu server utuh. Itu hanya bisa diuji bila ada lebih dari satu server.

### 2.4 Bug yang ditemukan dan sudah diperbaiki: chip emosi menampilkan `[object Object]`

**Milik siapa:** **milik Ridlo.** `Tugas-Ridlo.md` mencantumkan `web/js/galeri.js` sebagai file milik
Ridlo dan R3 menyebut galeri harus menampilkan "label emosi". Worker analisis emosi milik Ray
**sudah benar**: ia menghasilkan persis bentuk di kontrak. Yang salah hanya cara galeri membacanya.

**Apa yang terjadi:** kontrak (`kontrak/contoh/dianalisis.analisis-emosi.json`) menetapkan bahwa
`sentimen` adalah **objek** `{"skor": 0.42, "label": "positif"}`. Kode lama mengambil
`infoEmosi.sentimen` apa adanya dan menempelkannya ke teks, sehingga chip bertuliskan
**`Emosi: [object Object]`**.

**Perbaikan:** `web/js/galeri.js` kini punya fungsi `labelEmosiDariHasil()` yang hanya memakai teks
(bukan objek). Hasilnya "emosi dominan (sentimen)", misalnya **`Emosi: percaya (positif)`**. Emosi
dominan dipilih dari yang paling sering muncul di tiap bait.

**Pembuktian di browser:** data resmi kontrak menghasilkan `Emosi: percaya (positif)`; 12 kasus uji
(termasuk data kosong, objek kosong, daftar berisi sampah, dan kasus seri) semuanya benar tanpa error;
galeri memuat 12 kartu tanpa satu pun `[object Object]`; konsol browser bersih.

**Belum di-commit.** Perubahannya ada di working tree, jadi rekan Anda belum memilikinya.

> Catatan: browser menyimpan salinan JavaScript lama. Setelah file berubah, muat ulang paksa halaman
> (Ctrl+F5) supaya memakai versi baru.

### 2.5 Hal lain yang perlu Anda ketahui

1. **Klaster database tidak otomatis pulih setelah mati total.** Saat Docker dinyalakan ulang, semua
   node `poem-db` berstatus `OFFLINE` dan API menolak menulis. Perbaikannya ada di bagian 6. Ini akan
   terjadi lagi pada server AWS bila di-stop lalu dinyalakan.
2. **Folder `deploy/` adalah hasil uji di AWS sandbox** (9 server, 38 layanan); cara memakainya ada di
   `PANDUAN-DEPLOY-AWS.md`, dan arsitekturnya di `ARSITEKTUR-DEPLOY-AWS.md`. Draf lama yang tidak berfungsi sudah dihapus.
3. **Dokumen tugas di Downloads sudah usang** (bagian 2.1).

### 2.6 Kriteria "Selesai Bila"

| Kriteria | Status |
|---|---|
| Tahap submit, detail, dan genre pada `uji_e2e.py` LULUS | ✅ **LULUS** pada uji hari ini (8 dari 10 tahap lulus; dua sisanya, audio dan pencarian, milik teman) |
| Galeri menampilkan hasil seluruh fitur yang sudah di-merge tanpa perubahan kode tambahan | ✅ setelah bug chip emosi diperbaiki (2.4); belum di-commit |

---

## 3. Konsep dasar dari nol

### 3.1 Analogi: restoran

Bayangkan restoran besar.

- **Monolit (Tugas 1)** = satu koki mengerjakan semuanya: menerima pesanan, memasak, mencuci piring,
  mengantar. Kalau koki sakit, restoran tutup. Kalau ramai, satu koki tidak bisa dibelah dua.
- **Microservice (tugas sekarang)** = restoran dengan **bagian-bagian terpisah**: kasir, dapur
  panggang, dapur salad, pencuci piring. Masing-masing bisa ditambah orangnya sendiri-sendiri, dan kalau
  satu bagian macet, bagian lain tetap jalan.
- **Message broker (RabbitMQ)** = **papan tiket pesanan** di dapur. Kasir tidak berteriak ke koki satu
  per satu. Kasir menempel tiket di papan, lalu tiap koki mengambil tiket bagiannya. Kasir tidak perlu
  menunggu masakan jadi untuk melayani pelanggan berikutnya.

Itulah inti arsitektur ini: **pengguna kirim puisi, langsung dapat jawaban "diterima", dan analisis
(genre, tag, audio) dikerjakan belakangan oleh pekerja terpisah.**

### 3.2 Microservice dan container

- **Layanan (service)**: program kecil dengan satu tugas, misalnya `poem-service` (menyimpan dan
  menampilkan puisi) atau `klasifikasi-genre` (menentukan jenis puisi).
- **Container**: kotak terisolasi berisi satu program beserta semua yang dibutuhkannya. Seperti
  rice cooker: Anda tidak perlu tahu cara kerja di dalamnya, cukup colokkan.
- **Docker**: program yang menjalankan container. **Docker Compose**: berkas resep yang berkata
  "nyalakan 20 container ini, sambungkan begini". Berkas resepnya ada di `compose.yaml` dan folder
  `compose/`.
- **Replika**: salinan layanan yang sama. `poem-service` punya 2 replika, jadi bila satu mati, yang
  lain menjawab. Pembagian kerja antar replika dilakukan otomatis.

### 3.3 Gateway (Nginx)

Pintu depan satu-satunya. Browser hanya berbicara ke `http://localhost` (port 80). Gateway melihat alamat
yang diminta lalu meneruskan ke layanan yang tepat:

| Alamat yang diminta | Diteruskan ke |
|---|---|
| `/api/auth/...` | auth-service (milik Ifham) |
| `/api/puisi...` | poem-service (milik Ridlo) |
| `/api/search...` | search-service (milik Evan) |
| `/audio/...` | penyimpanan audio |
| `/` | berkas halaman web |

Aturan per layanan ada di `gateway/rute/*.conf`. Gateway juga menyimpan sementara jawaban (cache) selama
10 detik untuk daftar puisi.

### 3.4 Message broker: RabbitMQ

RabbitMQ adalah kantor pos. Ada empat istilah yang harus Anda kenali:

| Istilah | Arti | Contoh di proyek ini |
|---|---|---|
| **Exchange** | loket yang menerima pesan | `puisi.events` |
| **Routing key** | label di amplop yang menentukan tujuan | `puisi.dibuat`, `puisi.dianalisis`, `audio.siap` |
| **Queue (antrean)** | kotak surat tempat pesan menunggu | `q.klasifikasi-genre`, `q.puisi-hasil` |
| **Binding** | aturan "amplop berlabel X masuk ke kotak Y" | `puisi.dibuat` masuk ke `q.klasifikasi-genre` |

Satu pesan berlabel `puisi.dibuat` **disalin** ke semua kotak yang terikat padanya. Itu sebabnya satu
puisi baru otomatis sampai ke worker auto-tagging, genre, audio, emosi, dan pencarian sekaligus, tanpa
poem-service tahu siapa saja mereka.

- **Consumer**: program yang mengambil pesan dari sebuah kotak. **Ack** = lapor "pesan ini sudah selesai
  saya kerjakan"; hanya setelah ack pesan dihapus. Kalau consumer mati sebelum ack, pesan dikembalikan.
- **DLQ (dead letter queue)**: kotak untuk pesan yang gagal terus. Setelah 3 kali gagal, pesan dipindah
  ke `q.<nama>.dlq` agar tidak berputar selamanya. Anda bisa memeriksanya manual.
- **Quorum queue + 3 node**: setiap antrean disalin ke 3 server RabbitMQ. Satu server mati, pesan aman.
- **Idempoten**: memproses pesan yang sama dua kali menghasilkan keadaan akhir yang sama. Wajib, karena
  broker bisa mengirim ulang pesan.

Seluruh daftar exchange, queue, dan binding ditulis **sekali** di `rabbitmq/definitions.json`, lalu
dimuat otomatis saat RabbitMQ menyala. Tidak ada yang perlu Anda buat manual.

### 3.5 Transactional outbox

**Masalah:** poem-service harus menyimpan puisi **dan** mengirim pesan. Kalau database berhasil tetapi
RabbitMQ sedang mati, puisi tersimpan tetapi tidak ada analisis, selamanya.

**Solusi:** simpan puisi dan "surat yang mau dikirim" di database **dalam satu transaksi** (keduanya
berhasil atau keduanya batal). Surat itu ada di tabel `outbox`. Program terpisah bernama **poem-relay**
bertugas mengambil surat dari `outbox` dan mengirimnya ke RabbitMQ. Bila RabbitMQ sedang mati, surat
menunggu di `outbox` dan terkirim begitu RabbitMQ hidup.

Bukti dari uji hari ini: setelah beberapa puisi dikirim, tabel `outbox` punya 67 baris dan **0 yang belum
terkirim**.

### 3.6 Cache (Redis)

Cache = catatan jawaban yang sering diminta, supaya tidak menghitung ulang dari database.

| Lapisan | Penyimpan | Lama |
|---|---|---|
| 1 | Nginx (gateway) | 10 detik |
| 2 | Redis | 60 detik |
| 3 | Database (sumber asli) | |

Pada uji hari ini terlihat: permintaan pertama `MISS` dari database, kedua `HIT` dari Nginx, dan setelah
Nginx kedaluwarsa jawaban datang dari Redis. Kalau Redis mati, kode tetap membaca dari database
(`try/catch`), jadi Redis tidak boleh menjadi titik gagal.

### 3.7 JWT (token login)

Setelah login, auth-service memberi **token**: sebuah teks panjang yang menyatakan "ini pengguna X,
berlaku sampai jam Y", **ditandatangani** dengan kunci rahasia. Browser menyimpannya dan menyertakannya
di setiap kiriman puisi (`Authorization: Bearer <token>`).

poem-service **tidak bertanya ke auth-service** setiap saat. Ia memeriksa tanda tangan sendiri dengan
kunci rahasia yang sama (Docker secret `jwt_secret`). Itu sebabnya kedua layanan hanya perlu berbagi
satu kunci, tanpa saling memanggil. Ini yang membuat layanan "stateless" (tidak menyimpan sesi).

---

## 4. Bagaimana semua layanan tersambung

### 4.1 Perjalanan satu puisi

Ikuti nomor di bawah. Setiap nomor bisa Anda lihat langsung dengan perintah di bagian 4.4.

1. **Browser → gateway.** Anda menekan "Kirim Puisi". Browser mengirim `POST /api/puisi` beserta token.
2. **Gateway → poem-service** (salah satu dari 2 replika), sesuai `gateway/rute/puisi.conf`.
3. **poem-service** memeriksa token (tanda tangan dan masa berlaku), memeriksa isian (judul dan isi
   wajib), lalu **dalam satu transaksi** menulis baris ke tabel `puisi` dan tabel `outbox`. Ia membalas
   **202 "diterima, sedang diproses"**. Pengguna tidak menunggu analisis.
4. **poem-relay** melihat baris baru di `outbox`, mengirimnya ke exchange `puisi.events` dengan label
   `puisi.dibuat`, menunggu konfirmasi RabbitMQ, lalu menandai baris itu terkirim.
5. **RabbitMQ** menyalin pesan ke kotak-kotak yang terikat pada `puisi.dibuat`:
   `q.auto-tagging`, `q.klasifikasi-genre`, `q.text-to-speech`, `q.analisis-emosi`,
   `q.pencarian-indeks` (dan `q.tap` untuk pengintaian saat pengembangan).
6. **Worker klasifikasi-genre** (milik Ridlo) mengambil pesan dari `q.klasifikasi-genre`, menentukan
   pantun / syair / gurindam / puisi bebas, lalu mengirim pesan baru berlabel `puisi.dianalisis`
   berisi `sumber: klasifikasi-genre` dan hasilnya. Worker lain melakukan hal serupa dengan hasil mereka.
7. Pesan `puisi.dianalisis` masuk ke `q.puisi-hasil` (dan `q.pencarian-indeks`). **poem-consumer**
   mengambilnya, menggabungkan hasilnya ke baris puisi di database (kategori dan keyword hanya diisi bila
   kosong), mengubah status, dan menghapus cache Redis. Status menjadi `sebagian` lalu `selesai` setelah
   `auto-tagging` dan `klasifikasi-genre` sama-sama masuk (daftar sumber wajib ada di `SUMBER_WAJIB`).
8. **Browser** memuat ulang galeri setiap 5 detik selama masih ada puisi berstatus diproses, sehingga
   kartu berubah sendiri tanpa Anda menekan refresh.

Bila langkah 6 atau 7 gagal: pesan diulang sampai 3 kali, lalu masuk DLQ (`q.<nama>.dlq`).

### 4.2 Tidak ada yang disambung manual

Banyak pemula mengira ada langkah "menghubungkan layanan A ke layanan B". Di proyek ini tidak ada.
Penyambungan terjadi lewat **lima perekat** yang sudah tertulis di berkas:

| Perekat | Fungsinya | Lokasi |
|---|---|---|
| **1. Nama container** | Docker membuat jaringan dan memberi tiap container sebuah nama. Layanan cukup menulis `redis` atau `rabbitmq-1` sebagai alamat | semua berkas `compose/*.yaml` |
| **2. Variabel lingkungan** | Alamat dan sandi diberikan lewat pengaturan, bukan ditulis di kode: `AMQP_URLS` (alamat RabbitMQ), `DB_WRITE_HOSTS`, `REDIS_HOSTS`, `QUEUE` (antrean yang dibaca) | bagian `environment:` di `compose/puisi.yaml` dan `compose/klasifikasi-genre.yaml` |
| **3. Topologi RabbitMQ** | Exchange, antrean, dan binding dibuat otomatis saat RabbitMQ menyala | `rabbitmq/definitions.json` |
| **4. Berkas rute gateway** | Memetakan alamat URL ke layanan | `gateway/rute/*.conf` |
| **5. Kontrak** | Kesepakatan bentuk pesan JSON, isi token, dan nama rute yang dipegang semua anggota | `kontrak/README.md` |

Artinya: seorang anggota tim cukup menulis layanannya sesuai kontrak, menaruh berkas Compose dan
berkas rute miliknya, lalu layanannya **otomatis tersambung** begitu dinyalakan.

### 4.3 Peta koneksi

| Dari | Ke | Lewat | Pengaturan |
|---|---|---|---|
| Browser | gateway | HTTP port 80 | `http://localhost` |
| gateway | poem-service | proxy | `gateway/rute/puisi.conf` → `http://poem-service:8080` |
| poem-service | database (tulis) | MySQL | `DB_WRITE_HOSTS` → router port **6446** |
| poem-service | database (baca) | MySQL | `DB_READ_HOSTS` → router port **6447**, cadangan ke port 6446 dan node langsung |
| poem-service | Redis | Redis | `REDIS_HOSTS=redis:6379` |
| poem-relay | RabbitMQ | AMQP | `AMQP_URLS` (3 node, dicoba berurutan) |
| klasifikasi-genre | RabbitMQ | AMQP | `AMQP_URLS`, `QUEUE=q.klasifikasi-genre` |
| poem-consumer | RabbitMQ | AMQP | `AMQP_URLS`, `QUEUE_HASIL=q.puisi-hasil` |
| auth-service | poem-service | **tidak langsung** | berbagi kunci JWT lewat Docker secret `jwt_secret` |
| semua layanan | satu sama lain | pesan, bukan panggilan langsung | exchange `puisi.events` |

`AMQP_URLS` berisi tiga alamat (`rabbitmq-1`, `-2`, `-3`) yang dicoba berurutan. Itu sebabnya satu node
RabbitMQ yang mati tidak menghentikan layanan.

### 4.4 Melihat sendiri alurnya

Jalankan di PowerShell, di folder proyek, setelah semua menyala (bagian 5).

Lihat isi antrean dan jumlah consumer (kolom *consumer* untuk `q.klasifikasi-genre` harus 2):

```powershell
python scripts/status_antrian.py
```

Panel web RabbitMQ: buka <http://localhost:15672> (pengguna `puisi`, sandi `puisi`), menu **Queues**.
Kirim satu puisi lewat web lalu lihat angka berubah.

Lihat event yang lewat (jalankan ini, lalu kirim puisi dalam 15 detik):

```powershell
python scripts/intip_event.py --tunggu 15
```

Ikuti log relay yang mengirim dari outbox:

```powershell
docker compose logs -f --tail 10 poem-relay
```

Ikuti log worker genre:

```powershell
docker compose logs -f --tail 10 klasifikasi-genre
```

Setiap baris log memuat `correlation_id`, yaitu nomor yang sama dari gateway sampai worker terakhir,
sehingga satu puisi bisa dilacak.

---

## 5. Menjalankan di laptop (Windows)

Syarat: Docker Desktop menyala (ikon paus di baris tugas berwarna stabil), Python 3 terpasang.
Jalankan di PowerShell, di folder `D:\GitHub\puisi-monolithic-app`.

Buat rahasia lokal (sekali saja per mesin; folder `secrets/` tidak ikut git):

```powershell
python scripts/siapkan_rahasia.py
```

```powershell
python scripts/siapkan_rahasia_auth.py
```

Nyalakan bagian inti (infrastruktur, puisi, genre, auth, auto-tagging, emosi):

```powershell
docker compose --profile puisi --profile genre --profile auth --profile auto-tagging --profile emosi up -d --build
```

Cek hasilnya (huruf `-a` membuat container yang sudah selesai tugasnya, seperti `poem-db-cluster-init`,
ikut tampil):

```powershell
docker compose ps -a
```

Jalankan uji otomatis:

```powershell
python scripts/uji_e2e.py
```

Nyalakan semuanya sekaligus (berat, butuh banyak memori):

```powershell
docker compose --profile semua up -d --build
```

Menghentikan tanpa menghapus data:

```powershell
docker compose --profile semua stop
```

Laptop Anda punya sekitar 9,6 GiB memori untuk Docker. Bagian inti memakai sekitar 3,4 GiB (terukur),
tetapi profile `semua` belum diukur dan kemungkinan terlalu berat.

---

## 6. Masalah yang sering muncul

### 6.1 Docker Desktop: "An unexpected error occurred ... The file cannot be accessed by the system"

Pesan lengkapnya menyebut `sailor-ingest.sock` atau `docker-secrets-engine\engine.sock`. Penyebabnya:
sisa berkas soket dari penutupan Docker yang tidak rapi (di laptop Anda bertanggal 8 November), yang
tidak bisa diganti nama oleh Docker maupun dihapus oleh Windows.

**Jangan klik "Reset to factory defaults"**: itu menghapus semua image, container, dan volume Docker Anda
(termasuk data database lokal).

Perbaikan yang berhasil hari ini (cukup **ganti nama** folder, jangan hapus):

```powershell
Get-Process | Where-Object { $_.ProcessName -in @('Docker Desktop','com.docker.backend','com.docker.build') } | Stop-Process -Force
```

```powershell
Rename-Item "$env:LOCALAPPDATA\Docker\run" "run.lama1"
```

```powershell
Rename-Item "$env:LOCALAPPDATA\docker-secrets-engine" "docker-secrets-engine.lama1"
```

Lalu nyalakan Docker Desktop lagi. Bila nama folder sudah ada, ganti `lama1` dengan nama lain.

Hari ini saya sudah melakukannya, sehingga ada folder cadangan `Docker\run.lama-20261123`,
`Docker\run.lama2-20261123`, dan `docker-secrets-engine.lama-20261123`. Aman diabaikan; coba hapus nanti
setelah komputer di-restart.

**Pencegahan:** tutup Docker Desktop lewat menunya (**Quit Docker Desktop**), jangan mematikan paksa atau
membiarkan laptop mati mendadak saat Docker berjalan.

### 6.2 Semua node database `OFFLINE` setelah Docker/server menyala ulang

Gejala: unggah puisi gagal (503), atau perintah ini menampilkan `OFFLINE`:

```powershell
docker exec puisi-poem-db-1-1 mysql -uroot -ppoem -e "select member_host, member_state, member_role from performance_schema.replication_group_members"
```

Penyebab: klaster MySQL tidak otomatis bangun setelah **semua** node mati bersamaan. Skrip pemulihannya
ada di container `poem-db-cluster-init`, tetapi container itu hanya jalan sekali di awal.

Perbaikan (tidak menghapus data):

```powershell
docker start -a puisi-poem-db-cluster-init-1
```

Tunggu sampai tertulis `InnoDB Cluster 3-node siap.` dengan 3 baris `ONLINE`. Lalu:

```powershell
docker restart puisi-poem-db-router-1-1 puisi-poem-db-router-2-1
```

### 6.3 Halaman terbuka tetapi API menjawab 503 "Layanan untuk rute ini belum dijalankan"

Layanan di balik rute itu belum dinyalakan. Nyalakan profile-nya (bagian 5).

### 6.4 Puisi terus berstatus "diproses"

Periksa `python scripts/status_antrian.py`. Bila kolom *consumer* untuk `q.klasifikasi-genre` atau
`q.puisi-hasil` bernilai 0, worker atau consumer tidak jalan. Periksa juga status database (6.2).
Catatan: status baru menjadi `selesai` bila **kedua** sumber wajib (`auto-tagging` dan
`klasifikasi-genre`) sudah masuk; bila auto-tagging tidak dinyalakan, status berhenti di `sebagian`.

### 6.5 Sisa data uji di laptop

Pengujian hari ini meninggalkan jejak berikut di laptop Anda. Semuanya tidak berbahaya, dan tidak ada
yang di-commit:

| Jejak | Keterangan |
|---|---|
| Puisi uji nomor 63 sampai 74 di database lokal | dari uji gateway, uji anti-SPOF, dan `uji_e2e.py` (penulis "Ridlo Uji", "Penyair Uji", "Penyair E2E", dan satu puisi berjudul "x") |
| Beberapa pengguna `e2e...` di database auth | dibuat otomatis oleh `uji_e2e.py` |
| Container `auto-tagging`, `auth` (database + 2 layanan), dan `analisis-emosi` | masih menyala |
| Berkas rahasia lokal di `secrets/` | `auth_db_*.txt` dan 7 berkas hasil `siapkan_rahasia_tts.py` (tidak ikut git) |
| Primary database kini `poem-db-3` | hasil failover pada uji anti-SPOF; tidak masalah |
| Sisa potongan image yang tidak selesai diunduh | memakai sedikit disk; bersihkan dengan `docker builder prune` bila perlu |
| `web/js/galeri.js` berubah | perbaikan chip emosi, belum di-commit |

### 6.6 Setelah `docker swarm init`, nama layanan tidak lagi terselesaikan

**Gejala:** container Compose masih `Up`, tetapi gateway menjawab `503` (`could not be resolved` untuk `poem-service`, `redis`, `rabbitmq-1`). Terjadi 23 November 2026 saat `deploy/swarm/stack.yaml`
diperiksa di laptop: `docker swarm init` lalu `docker swarm leave --force` saat stack Compose berjalan menghapus catatan nama layanan di jaringan Compose (penyebab pastinya dugaan, efeknya teramati).

**Pencegahan:** jangan menguji Swarm di laptop selagi Compose berjalan; di laptop cukup `docker stack config -c deploy/swarm/stack.yaml`. Swarm sungguhan diuji di AWS.

**Bila sudah terlanjur:** untuk setiap container `X`: `docker rename X X-tmpdns` lalu `docker rename X-tmpdns X` (mendaftarkan ulang nama tanpa menghentikan container; terbukti memulihkan 24 container dan klaster 3 ONLINE). Hapus juga jaringan `docker_gwbridge` sisa Swarm bila ada.

Hentikan layanan tambahan bila tidak perlu:

```powershell
docker compose --profile auto-tagging stop auto-tagging
```

```powershell
docker compose --profile auth stop auth-service auth-db
```

```powershell
docker compose --profile emosi stop analisis-emosi
```

---

## 7. Urutan kerja bersama teman

**Langkah 0: pastikan kebutuhan tugas.** Tanyakan ke kelompok: apakah dosen mewajibkan demo yang
berjalan di AWS, atau cukup dokumen rancangan (`tugas-dari-dosen.md` hanya menyebut dokumen)? Itu
menentukan seberapa banyak waktu yang layak dihabiskan untuk deploy.

**Langkah 1: Ridlo meng-commit perbaikan galeri.** Bug chip emosi sudah diperbaiki dan terbukti di browser
(bagian 2.4), tetapi perubahannya baru ada di laptop Anda. Tanpa commit dan push, server AWS dan teman
tidak memilikinya.

**Langkah 2: rapikan branch.** Saya memeriksa branch yang belum masuk `main`:

| Branch | Isi | Saran |
|---|---|---|
| `origin/evan/visibilitas-bawaan-publik` | 1 commit, hanya menyentuh layanan pencarian milik Evan | Evan membuat pull request sendiri |
| `origin/mount_dari_branch_pison` | 14 commit, menghapus berkas monolit lama di root (`server.php`, `index.html`, dll.) | **Jangan di-merge begitu saja.** Tampaknya sisa riwayat lama sebelum berkas dipindah ke `legacy/`. Tanyakan Ifham dan Pison dulu |
| `backup/lokal-sebelum-sync` (lokal) | 2 commit cadangan lokal | Abaikan |

Branch `ridlo/layanan-puisi` dan `ridlo/klasifikasi-genre` sudah sama dengan isi `main`, tidak ada
yang tertinggal. (Catatan: saya hanya membaca judul commit dan daftar berkasnya, bukan isinya secara
mendalam.)

**Langkah 3: satu orang menguji semuanya di laptop.** Jalankan `docker compose --profile semua up -d --build`
bila memori cukup (atau bertahap per profile), lalu `python scripts/uji_e2e.py`. Tujuannya: semua tahap
LULUS sebelum dibawa ke AWS. Bila ada yang BELUM, tahap itu menunjukkan layanan siapa yang bermasalah.

**Langkah 4: satu orang (yang memegang sandbox AWS) men-deploy** mengikuti
[`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md). Teman tidak perlu men-deploy sendiri-sendiri.

**Langkah 5: semua orang menguji tahapnya lewat alamat publik.** Setiap orang mengecek bagian miliknya
dan mengambil tangkapan layar sebagai bukti untuk laporan:

| Pemilik | Yang dicek |
|---|---|
| Ifham | register, login, audio muncul di kartu puisi |
| Ridlo | kirim puisi, status berubah, genre muncul, galeri, cache (`X-Cache-Status`, `X-Cache-Layer`) |
| Evan | pencarian menemukan puisi baru |
| Pison | gateway, RabbitMQ (3 node), auto-tagging |
| Ray | analisis emosi, observability (Grafana) |

Memperbarui server setelah ada perubahan kode (di server, di folder proyek):

```bash
git pull
docker compose --profile puisi --profile genre --profile auth --profile auto-tagging --profile emosi up -d --build
```

**Langkah 6: perbarui dokumen rancangan** dengan hasil nyata (angka uji, tangkapan layar) dan jelaskan
dengan jujur apa yang dibuktikan dan apa yang belum.

---

## 8. Daftar istilah

| Istilah | Arti sederhana |
|---|---|
| **Microservice** | aplikasi dipecah menjadi layanan kecil, masing-masing satu tugas |
| **Container** | kotak terisolasi berisi satu program dan kebutuhannya |
| **Docker / Docker Compose** | program penjalan container / berkas resep untuk menyalakan banyak container |
| **Image** | cetakan untuk membuat container |
| **Profile (Compose)** | label untuk memilih kelompok layanan yang dinyalakan |
| **Replika** | salinan layanan yang sama untuk berbagi beban dan cadangan |
| **Gateway / Reverse proxy** | pintu depan yang meneruskan permintaan ke layanan yang tepat |
| **Message broker (RabbitMQ)** | kantor pos antar layanan |
| **Exchange, queue, binding, routing key** | loket, kotak surat, aturan pemasukan, label amplop |
| **Consumer, ack** | pembaca kotak surat, lapor "sudah selesai" |
| **DLQ** | kotak untuk pesan yang gagal terus |
| **Quorum queue** | antrean yang disalin ke beberapa node RabbitMQ |
| **Outbox / relay** | tabel surat-yang-mau-dikirim / pengirim surat dari tabel itu |
| **Idempoten** | diproses dua kali, hasilnya sama |
| **Cache-aside** | cek catatan dulu, kalau tidak ada baru tanya sumber asli lalu catat |
| **TTL** | masa berlaku catatan cache |
| **JWT** | token login bertanda tangan |
| **Docker secret** | cara aman memberi sandi/kunci ke container |
| **InnoDB Cluster** | 3 server MySQL yang saling menyalin; satu menulis, dua cadangan |
| **MySQL Router** | penunjuk jalan ke server MySQL yang sedang menjadi penulis atau pembaca |
| **SPOF** | satu titik yang bila rusak membuat semuanya mati |
| **Stateless** | layanan tidak menyimpan sesi pengguna di dalam dirinya |
| **EC2** | komputer virtual di AWS |
| **Security Group** | daftar pintu jaringan yang boleh dimasuki dari internet |
| **Region / AZ** | lokasi pusat data AWS / ruang terpisah di dalam satu lokasi |
