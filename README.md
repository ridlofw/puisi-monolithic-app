# Aplikasi Puisi

Platform publikasi puisi untuk mata kuliah **Pengembangan Perangkat Lunak Scalable**. Satu aplikasi
yang berevolusi sepanjang semester:

| Tahap | Arsitektur | Lokasi |
|---|---|---|
| Tugas 1 | monolit stateful, PHP dan MySQL, sesi di RAM server | `legacy/` |
| Hands-on Minggu 5 | microservice gambar di AWS Lambda di belakang CloudFront | `lambda/` |
| Hands-on Arsitektur | microservice dan event-driven: gateway Nginx, RabbitMQ tiga node, Redis, layanan per fitur | seluruh repositori |

## Arsitektur

```
browser -> gateway Nginx (proxy_cache) -> auth-service    -> auth-db
                                       -> poem-service    -> poem-db + replika, Redis
                                       -> search-service  -> OpenSearch, Redis
poem-service --outbox--> RabbitMQ (puisi.events, 3 node)
          -> Auto-tagging, Klasifikasi Genre, Text-to-Speech, Analisis Emosi
          -> puisi.dianalisis, audio.siap -> poem-service, search-service
```

Kontrak antarlayanan, yaitu rute API, JWT, bentuk event, queue, dan aturan Compose, ada di
[`kontrak/README.md`](kontrak/README.md). Baca itu sebelum menulis layanan.

| Komponen | Folder | Fragmen Compose | Pemilik |
|---|---|---|---|
| Gateway, RabbitMQ, Redis | `gateway/`, `rabbitmq/` | `compose/infra.yaml` | Pison |
| Templat worker | [`workers/_templat/`](workers/_templat/README.md) | `compose/templat.yaml` | Pison |
| auth-service | `services/auth/` | `compose/auth.yaml` | Ifham |
| poem-service | `services/puisi/` | `compose/puisi.yaml` | Ridlo |
| search-service | `services/pencarian/` | `compose/pencarian.yaml` | Evan |
| Auto-tagging | `workers/auto-tagging/` | `compose/auto-tagging.yaml` | Pison |
| Klasifikasi Genre | `workers/klasifikasi-genre/` | `compose/klasifikasi-genre.yaml` | Ridlo |
| Text-to-Speech | `workers/text-to-speech/` | `compose/text-to-speech.yaml` | Ifham |
| Analisis Emosi | `workers/analisis-emosi/` | `compose/analisis-emosi.yaml` | Ray |
| Observability | `observability/` | `compose/observability.yaml` | Ray |
| Frontend | `web/`, satu modul per area di `web/js/` | dilayani gateway | pemilik modul |

## Menjalankan

Butuh Docker Desktop dan Python 3 untuk script uji.

```
python scripts/siapkan_rahasia.py                 # sekali per mesin
docker compose up -d                              # gateway, RabbitMQ tiga node, Redis
docker compose --profile legacy up -d             # ditambah monolit Tugas 1 di /legacy/
docker compose --profile auto-tagging up -d       # ditambah satu layanan, nama profile ada di kontrak
docker compose --profile semua up -d              # semuanya
```

| Alamat | Isi |
|---|---|
| <http://localhost> | aplikasi |
| <http://localhost:15672> | management RabbitMQ, pengguna `puisi`, sandi `puisi`. Node 2 dan 3 di 15673 dan 15674 |

Frontend memakai `/api/auth/` untuk registrasi dan login. Aksi puisi yang belum dipindah tetap
tersedia lewat `KONFIG.backend` di `web/js/api.js`.

### Auth service (profile `auth`)

Buat secret lokal sebelum menjalankan layanan:

```
python scripts/siapkan_rahasia.py
python scripts/siapkan_rahasia_auth.py
docker compose --profile auth up -d --build
```

Fragmen Compose auth menjalankan MySQL 8.4 dan dua replika auth-service dengan database dan JWT
signing secret yang sama. Registrasi dan login tersedia di `/api/auth/register` dan `/api/auth/login`.
Browser menyimpan bearer token satu jam di `localStorage` dengan kunci `puisi.token`; decoding klaim
di browser hanya mengatur tampilan. Layanan terlindungi harus memverifikasi tanda tangan JWT sendiri.
JavaScript dapat membaca `localStorage`, sehingga XSS dapat membocorkan token; pertahankan escaping
output dan gunakan Content Security Policy yang kuat.

The auth service has no PHP session state and does not set authentication cookies. See
`services/auth/README.md` for secret handling, API details, and test commands.

## Menguji

```
python scripts/status_antrian.py --node                               # klaster dan isi queue
python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json  # suntik event contoh
python scripts/intip_event.py --tunggu 10                             # lihat event hasil
python scripts/uji_e2e.py                                             # alur lengkap, LULUS atau BELUM
```

Yang sudah dibuktikan pada kerangka ini:

| Uji | Hasil |
|---|---|
| Klaster RabbitMQ | tiga node berjalan, ke-13 quorum queue punya tiga anggota |
| Pesan rusak | tepat tiga percobaan, lalu masuk `q.auto-tagging.dlq` dengan alasan `rejected` |
| Satu node RabbitMQ dimatikan | event tetap diterima, worker pindah node, 4 dari 4 event diproses, tidak ada yang hilang |
| Tiga replika worker, 30 event | terbagi 10, 10, 10 |
| Vektor JWT | token dari Python dan PHP 8.3 identik byte demi byte |
| Frontend setelah dipecah per modul | register, login, galeri, reload sesi, submit, logout lewat Chrome headless, tanpa error JavaScript |

## Fitur Gambar Puisi (Hands-on Minggu 5)

Setiap puisi memiliki gambar kutipan yang dirender oleh microservice di AWS Lambda dan dilayani lewat
CloudFront.

- **Form submit** memiliki kolom *bait kutipan*, pilihan template latar, dan **preview yang berubah
  otomatis** setiap kali judul, bait, atau template diubah.
- **Submit berjalan dua langkah.** Frontend memanggil `action=save` agar microservice merender dan
  mengunggah gambar ke S3, lalu nama file yang dikembalikan dikirim bersama metadata puisi ke backend.
- **Daftar puisi tampil sebagai galeri gambar**, lengkap dengan tautan unduh, bukan tabel teks.

### Konfigurasi Endpoint

Semua alamat dikumpulkan pada objek `KONFIG` di `web/js/api.js`.

| Kunci | Arti | Contoh |
|---|---|---|
| `backend` | lokasi backend monolit | `/legacy/server.php` |
| `cdn` | basis URL CloudFront. Kosongkan bila halaman ini sudah dilayani CloudFront | `https://<id>.cloudfront.net` |
| `pathGambar` | path behavior microservice | `/fungsi` |
| `template` | daftar file latar di bucket S3 | `latar1`, `latar2`, `latar3`, `latar5` |
| `jedaPreview` | jeda sebelum preview dimuat ulang, dalam milidetik | `600` |
| `kunciToken` | kunci `localStorage` untuk JWT | `puisi.token` |

Berkas latar berasal dari dosen dan diunggah ke root bucket S3, sehingga thumbnail template maupun
gambar hasil render diambil dari domain CloudFront yang sama. Tanpa CDN, preview dan submit gagal
dengan pesan yang jelas.

### Kontrak dengan Microservice Gambar

```
/fungsi?action=preview&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
/fungsi?action=save&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
```

`preview` mengembalikan JPEG biner untuk tag `<img>`, sedangkan `save` mengunggah gambar ke S3 lalu
mengembalikan `{"status":"sukses","file_gambar":"puisi_xxx.jpeg"}`. Seluruh nilai teks dikirim
melalui `encodeURIComponent`. Kode fungsinya ada di [`lambda/`](lambda/README.md).

## Monolit Tugas 1

`legacy/` menyimpan backend asli tanpa perubahan sebagai pembanding: PHP murni tanpa framework, satu
pintu `server.php?aksi=...`, sesi lokal `session_start()`, dan MySQL lewat PDO dengan skema
`query.sql`. Profile `legacy` menjalankannya di container `php:8.3-apache` dan `mysql:8.4`, dilayani
gateway di `/legacy/`.

Deployment aslinya ke AWS EC2 t2.micro: Security Group membuka port 80 dan 22, pasang
`apache2 php libapache2-mod-php php-mysql mysql-server`, impor `query.sql`, salin `legacy/` ke
`/var/www/html/legacy/` dan isi `web/` ke `/var/www/html/`, lalu buka IP publik instance.
