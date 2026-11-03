# Kontrak Antarlayanan

Kesepakatan yang membuat setiap layanan dapat dibangun dan diuji tanpa layanan lain berjalan.
Mengubah isi berkas ini berarti mengubah pekerjaan semua anggota, jadi lakukan lewat pull request
yang direview seluruh kelompok.

## 1. Rute API melalui gateway

Semua respons JSON memakai bentuk yang sama dengan monolit Tugas 1:
`{"status": "sukses" | "error", "pesan": "...", "data": ...}`.

| Rute | Layanan | Keterangan |
|---|---|---|
| `POST /api/auth/register` | auth-service | body `username, password, nama, no_id`. 201, atau 409 bila username sudah ada |
| `POST /api/auth/login` | auth-service | 200, `data: {token, user: {id, username, nama}}` |
| `POST /api/puisi` | poem-service | wajib `Authorization: Bearer <token>`. Body `judul, isi, tgl_submit, kategori, keyword, file_gambar`, tiga yang terakhir boleh kosong. 202, `data: {id, status: "diproses"}` |
| `GET /api/puisi` | poem-service | galeri publik, di-cache Nginx dan Redis |
| `GET /api/puisi/{id}` | poem-service | `data: {id, judul, isi, penulis, tgl_submit, kategori, keyword, file_gambar, status_analisis, status_audio, analisis: {<sumber>: <hasil>}, url_audio}` |
| `GET /api/search?q=&genre=&tag=&hal=` | search-service | `data: [{id, judul, penulis, genre, tag, potongan}]` |
| `GET /audio/{berkas}` | object storage lewat gateway | berkas mp3 hasil Text-to-Speech |

Logout cukup menghapus token di browser. Frontend menyimpan token di `localStorage` dengan kunci
`puisi.token`, dan `panggil()` di `web/js/api.js` memasangnya otomatis.

Header yang membantu demo:

| Header | Diisi oleh | Nilai |
|---|---|---|
| `X-Request-ID` | gateway | id unik per request, diteruskan ke layanan dan menjadi `correlation_id` event |
| `X-Cache-Status` | gateway | `MISS`, `HIT`, `EXPIRED`, atau kosong bila rute tidak di-cache |
| `X-Cache-Layer` | layanan | `redis`, `db`, atau `opensearch`, lapisan yang menjawab |

Bila layanan sebuah rute belum dijalankan, gateway menjawab 503 dengan JSON berbentuk sama.

## 2. Token

JWT HS256 dengan klaim berurutan `sub` (id pengguna, string), `username`, `nama`, `iat`, `exp`,
berlaku satu jam. Header dan klaim diserialisasi JSON ringkas tanpa spasi, base64url tanpa padding.

Kunci dibaca dari Docker secret `jwt_secret`, yaitu berkas `secrets/jwt_secret.txt` yang tidak
di-commit. Buat sekali per mesin dengan `python scripts/siapkan_rahasia.py`.

`jwt-vektor.json` memuat kunci uji, token benar, token kedaluwarsa, dan token bertanda tangan salah.
Setiap implementasi JWT diuji terhadap vektor itu:

- penerbit (auth-service) harus menghasilkan `token_benar` persis dari `kunci` dan `klaim`;
- pemverifikasi (poem-service) harus menerima `token_benar`, menolak `token_kedaluwarsa`, dan menolak
  `token_tanda_tangan_salah`. Verifikasi dihitung atas dua segmen base64 apa adanya, jangan
  menyerialisasi ulang klaim, karena `json_encode` PHP meng-escape `/` sedangkan Python tidak.

Implementasi Python ada di `scripts/token_uji.py`, dan sudah dicocokkan byte demi byte dengan
`json_encode` dan `hash_hmac` PHP 8.3.

## 3. Event

Semua event lewat topic exchange `puisi.events` dengan amplop yang sama:

```json
{
  "event_id": "uuid",
  "tipe": "puisi.dibuat",
  "versi": 1,
  "terjadi_pada": "2026-11-03T07:30:00+00:00",
  "correlation_id": "id dari X-Request-ID",
  "data": {}
}
```

`correlation_id` diteruskan apa adanya ke setiap event turunan dan ditulis di setiap log, sehingga
satu puisi dapat ditelusuri dari gateway sampai worker terakhir.

| Routing key | Diterbitkan oleh | `data` |
|---|---|---|
| `puisi.dibuat` | poem-service, lewat relay outbox | `puisi_id, judul, isi, penulis, kategori, keyword`, dua terakhir boleh null |
| `puisi.dianalisis` | Auto-tagging, Klasifikasi Genre, Analisis Emosi | `puisi_id, sumber, hasil` |
| `audio.siap` | Text-to-Speech | `puisi_id, url_audio, durasi_detik, mesin` |

Bentuk `hasil` per `sumber`:

| `sumber` | `hasil` |
|---|---|
| `auto-tagging` | `{keyword: [lima kata dasar], kategori}` |
| `klasifikasi-genre` | `{genre: pantun / syair / gurindam / puisi bebas, skema_rima}` |
| `analisis-emosi` | `{sentimen: {skor, label}, emosi_dominan_per_bait: [...]}` |

poem-service menyimpan `hasil` per `sumber` apa adanya, jadi sumber baru tidak memerlukan perubahan
poem-service. Contoh setiap event ada di `contoh/`. Berkas di sana hanya berisi bagian `data`,
`scripts/kirim_event.py` yang membungkusnya dengan amplop.

## 4. Queue

| Queue | Binding | Consumer |
|---|---|---|
| `q.auto-tagging` | `puisi.dibuat` | Auto-tagging |
| `q.klasifikasi-genre` | `puisi.dibuat` | Klasifikasi Genre |
| `q.text-to-speech` | `puisi.dibuat` | Text-to-Speech |
| `q.analisis-emosi` | `puisi.dibuat` | Analisis Emosi |
| `q.puisi-hasil` | `puisi.dianalisis`, `audio.siap` | poem-service |
| `q.pencarian-indeks` | `puisi.dibuat`, `puisi.dianalisis` | search-service |
| `q.tap` | `#` | khusus pengembangan, dibaca `scripts/intip_event.py` |

Semua queue bertipe quorum dan direplikasi ke tiga node RabbitMQ. Topologinya dideklarasikan sekali
di `rabbitmq/definitions.json`, jadi event tetap tertampung walaupun worker belum dijalankan.
Consumer cukup mengonsumsi, tidak perlu mendeklarasikan apa pun. Pada start dari volume kosong, queue
dibuat sebelum ketiga node bergabung, lalu RabbitMQ menambah anggotanya sampai tiga dalam kurang dari
satu menit. Periksa dengan `python scripts/status_antrian.py`.

**Pesan yang gagal tiga kali pindah ke `q.<nama>.dlq`.** RabbitMQ 4 tidak lagi menghitung
`basic.nack` dengan requeue ke `x-delivery-limit`, sehingga nack biasa membuat pesan rusak berputar
tanpa henti. Karena itu percobaan dihitung oleh consumer lewat header `x-percobaan`:

1. gagal pada percobaan 1 atau 2: terbitkan ulang pesan yang sama ke queue asalnya dengan
   `x-percobaan` naik satu, lalu ack yang lama;
2. gagal pada percobaan 3: `basic.reject` tanpa requeue, dead letter exchange `puisi.dlx`
   memindahkannya ke DLQ.

`workers/_templat/worker.py` sudah melakukannya. Layanan PHP yang mengonsumsi event harus meniru
aturan yang sama. `x-delivery-limit: 3` tetap terpasang sebagai pengaman untuk consumer yang crash
sambil memegang pesan.

**Consumer wajib idempoten.** Event yang sama diproses dua kali harus menghasilkan keadaan yang sama,
misalnya dengan upsert berdasarkan `puisi_id`.

Alamat broker untuk semua consumer, dicoba berurutan sehingga satu node yang mati tidak menghentikan
consumer:

```
AMQP_URLS=amqp://puisi:puisi@rabbitmq-1:5672/%2F,amqp://puisi:puisi@rabbitmq-2:5672/%2F,amqp://puisi:puisi@rabbitmq-3:5672/%2F
```

## 5. Aturan teknis lain

- **Satu fragmen Compose per pemilik.** `compose.yaml` hanya berisi include. Path di dalam fragmen
  relatif ke akar repositori. Setiap service diberi `profiles: ["<profile>", "semua"]` dan
  `restart: unless-stopped`.

  | Fragmen | Profile |
  |---|---|
  | `compose/auth.yaml` | `auth` |
  | `compose/puisi.yaml` | `puisi` |
  | `compose/pencarian.yaml` | `pencarian` |
  | `compose/auto-tagging.yaml` | `auto-tagging` |
  | `compose/klasifikasi-genre.yaml` | `genre` |
  | `compose/text-to-speech.yaml` | `tts` |
  | `compose/analisis-emosi.yaml` | `emosi` |
  | `compose/observability.yaml` | `observability` |

- **Satu berkas rute Nginx per layanan** di `gateway/rute/<layanan>.conf`. Pakai `proxy_pass`
  melalui variabel dan sertakan `proxy-umum.conf`, supaya gateway tetap menyala walaupun layanannya
  belum dijalankan. Contohnya `gateway/rute/legacy.conf`:

  ```nginx
  location /api/puisi {
      set $puisi http://poem-service:8080;
      proxy_pass $puisi;
      include /etc/nginx/proxy-umum.conf;
  }
  ```

  Zona cache `api_cache` sudah tersedia untuk `proxy_cache`.
- **Metrik.** Container yang punya `/metrics` diberi label `metrics.scrape: "true"` dan
  `metrics.port`. Prometheus menemukannya sendiri, tidak ada berkas target yang diedit bersama.
- **Redis** ada di `redis:6379`, tanpa persistensi. Prefix key per layanan: `puisi:`, `cari:`,
  `auth:`. Setiap layanan wajib tetap menjawab saat Redis mati.
- **Basis data hanya diakses pemiliknya**: auth-db oleh auth-service, poem-db oleh poem-service,
  tts-db oleh Text-to-Speech.
- **Object storage** dibawa sendiri oleh pemakainya di fragmennya. Image `minio/minio` tidak bisa
  di-pull dari Docker Hub saat dicoba 3 November 2026. `chrislusf/seaweedfs`, yang punya API S3, bisa.

## 6. Alat uji

Semua script memakai pustaka standar Python, jalan sama di Windows, macOS, dan Linux.

| Script | Kegunaan |
|---|---|
| `scripts/kirim_event.py <routing key> <berkas>` | terbitkan satu event contoh. `--ulang 30` untuk beban, `--mentah` untuk menguji DLQ, `--event-id` untuk menguji idempotensi |
| `scripts/intip_event.py` | baca event dari `q.tap`. `--tipe`, `--tunggu`, `--kosongkan` |
| `scripts/status_antrian.py` | isi setiap queue, consumer, anggota quorum. `--node` untuk status klaster |
| `scripts/siapkan_rahasia.py` | buat `secrets/jwt_secret.txt` sekali per mesin |
| `scripts/token_uji.py` | JWT untuk pengguna uji. `--periksa-vektor` mencocokkan dengan `jwt-vektor.json` |
| `scripts/uji_e2e.py` | alur lengkap lewat gateway, setiap tahap LULUS atau BELUM |

Script RabbitMQ memakai API management di port 15672, 15673, dan 15674 secara bergantian, jadi tetap
jalan saat satu node dimatikan.
