# 2. Bagaimana microservice saling terhubung

Pertanyaan yang wajar: "Ada belasan program kecil. Siapa yang menghubungkan mereka, dan bagaimana
caranya?" Jawaban singkatnya: **Anda hampir tidak perlu menghubungkan apa pun secara manual.**
Semua sambungan sudah tertulis di [`../stack.yaml`](../stack.yaml). Dokumen ini menjelaskan
*apa* yang tertulis di sana dan *mengapa itu berfungsi*, supaya Anda bisa memeriksanya bila ada yang
putus.

Baca dulu [`1-konsep-dasar.md`](1-konsep-dasar.md) bila istilah container, Swarm, atau overlay masih asing.


> **Catatan (23 November 2026):** konsepnya tetap berlaku, tetapi bagian yang menyebut **pool** seperti `pison` atau `ifham` menggambarkan rancangan awal. Di sandbox yang dipakai sungguhan,
> aplikasi berjalan di **9 server `t3.small`** (susunan di [`PANDUAN-DEPLOY-AWS.md`](../../../docs/PANDUAN-DEPLOY-AWS.md) bagian 0); nama pool hanyalah label penempatan.

---

## 1. Empat cara layanan berbicara

Bayangkan sebuah kantor. Ada empat cara orang berkomunikasi:

| Cara | Analogi kantor | Dipakai untuk |
|---|---|---|
| **A. Permintaan langsung (HTTP) lewat nama** | Menelepon rekan dengan nomor ekstensi | gateway ke poem-service, auth-service, search-service |
| **B. Pesan lewat RabbitMQ** | Menitipkan memo di kantor pos internal. Penerima mengambilnya saat sempat | Kabar "ada puisi baru" dan hasil analisis |
| **C. Basis data bersama milik satu layanan** | Lemari arsip yang kuncinya hanya dipegang satu orang | poem-service ke poem-db, auth-service ke auth-db |
| **D. Rahasia yang dibagikan** | Kata sandi yang diberikan lebih dulu kepada dua orang | Kunci tanda tangan token (JWT) |

### A. Memanggil lewat nama layanan

Di dalam jaringan Docker, **nama layanan adalah alamatnya**. Gateway tidak tahu nomor IP
poem-service; ia cukup menulis `http://poem-service:8080`. Docker punya "buku telepon" bawaan
(DNS internal) yang menerjemahkan nama itu menjadi alamat yang benar.

Contoh nyata dari `gateway/rute/puisi.conf`:

```nginx
location /api/puisi {
    set $puisi http://poem-service:8080;   # nama layanan + port
    proxy_pass $puisi;
    ...
}
```

Daftar rute di gateway (satu berkas per layanan di folder `gateway/rute/`):

| Bila pengunjung membuka | Gateway meneruskan ke |
|---|---|
| `/` (halaman web) | berkas di dalam gateway sendiri (folder `web/`) |
| `/api/auth/...` | `auth-service:8080` |
| `/api/puisi...` | `poem-service:8080` |
| `/api/search...` | `search-service:8080` |
| `/audio/...` | `seaweedfs:8333` |

Bila layanan tujuannya belum hidup, gateway menjawab JSON `503 Layanan sedang tidak tersedia`
(halaman web tetap terbuka).

**Di Swarm, apa bedanya dengan satu server?** Tidak ada yang berubah dari sisi program, tetapi di
belakangnya:

- Setiap layanan mendapat satu **alamat maya (VIP)**. Nama `poem-service` menunjuk ke alamat itu, lalu
  Swarm membagi panggilan ke salinan yang ada, di server mana pun.
- Untuk database dan RabbitMQ kita memakai **`endpoint_mode: dnsrr`**: nama langsung menunjuk ke alamat
  salinan yang sebenarnya, tanpa perantara. Ini perlu karena anggota klaster database dan RabbitMQ harus
  mengenali satu sama lain berdasarkan nama.
- Bila gateway di server 1 memanggil poem-service yang berada di server 2, paket data
  **dibungkus dan dikirim antar-server lewat port UDP 4789** (jaringan overlay).
  **Inilah sebabnya Security Group harus membuka 4789/udp, 7946, dan 2377 antar-server.**
  Bila lupa, layanan di server yang sama bisa saling bicara tetapi lintas server tidak.

### B. Pesan lewat RabbitMQ (komunikasi tidak langsung)

Tidak semua pekerjaan harus selesai saat pengunjung menunggu. Menganalisis puisi bisa lama. Maka
poem-service **tidak memanggil** auto-tagging secara langsung. Ia menitipkan kabar di RabbitMQ:
"puisi nomor 12 baru dibuat". Siapa pun yang berminat mengambilnya.

Istilah RabbitMQ:

| Istilah | Artinya |
|---|---|
| **Exchange** `puisi.events` | Loket pos yang menerima semua pesan |
| **Routing key** (`puisi.dibuat`, `puisi.dianalisis`, `audio.siap`) | Label pada pesan yang menentukan ke mana ia disalin |
| **Queue** (antrean, mis. `q.auto-tagging`) | Kotak surat milik satu pekerja. Pesan menunggu di sini sampai diambil |
| **Consumer** | Program yang mengambil pesan dari antrean |

Keuntungan terbesarnya: **bila pekerja sedang mati, pesan tetap menunggu di antrean** dan diproses
begitu pekerja hidup lagi. Tidak ada pesan yang hilang.

Antrean di proyek ini (dari `rabbitmq/definitions.json` dan `kontrak/README.md`):

| Antrean | Menerima pesan | Dikonsumsi oleh |
|---|---|---|
| `q.auto-tagging` | `puisi.dibuat` | auto-tagging |
| `q.klasifikasi-genre` | `puisi.dibuat` | klasifikasi-genre |
| `q.analisis-emosi` | `puisi.dibuat` | analisis-emosi |
| `q.text-to-speech` | `puisi.dibuat` | text-to-speech |
| `q.pencarian-indeks` | `puisi.dibuat` dan `puisi.dianalisis` | search-consumer |
| `q.puisi-hasil` | `puisi.dianalisis` dan `audio.siap` | poem-consumer |

Pesan yang gagal diproses tiga kali dipindahkan ke antrean "pesan bermasalah" (`.dlq`) supaya tidak
macet.

RabbitMQ kita berjumlah **tiga node** (`rabbitmq-1`, `-2`, `-3`) di tiga server pool `pison`. Semua program
menerima daftar ketiganya:

```
AMQP_URLS = amqp://puisi:puisi@rabbitmq-1:5672/%2F, amqp://puisi:puisi@rabbitmq-2:5672/%2F, amqp://puisi:puisi@rabbitmq-3:5672/%2F
```

Program mencoba dari yang pertama. Bila `rabbitmq-1` mati, ia otomatis mencoba `rabbitmq-2`.
Isi antrean disalin ke ketiga node (jenis *quorum queue*), jadi kehilangan satu node tidak
menghilangkan pesan.

### C. Basis data: satu pemilik, satu lemari

Aturan di `kontrak/README.md`: **basis data hanya diakses oleh pemiliknya.**

| Basis data | Hanya diakses oleh |
|---|---|
| poem-db (klaster 3 node) | poem-service, poem-relay, poem-consumer |
| auth-db (klaster 3 node, lewat Router) | auth-service |
| tts-db (klaster 3 node, lewat Router) | text-to-speech |

Layanan lain yang butuh data puisi **bertanya lewat HTTP atau menerima pesan**, tidak membaca
database orang lain. Dengan begitu satu tim bisa mengubah tabelnya tanpa merusak tim lain.

poem-db adalah klaster tiga node, jadi program tidak menyambung langsung ke satu node. Mereka
menyambung ke **MySQL Router** (`poem-db-router-1`, `-2`) yang selalu tahu node mana yang
sedang menjadi "ketua" (Primary):

| Variabel | Isi | Artinya |
|---|---|---|
| `DB_WRITE_HOSTS` | `poem-db-router-1:6446, poem-db-router-2:6446, poem-db-1:3306, ...` | Daftar tujuan **menulis**, dicoba berurutan |
| `DB_READ_HOSTS` | `poem-db-router-1:6447, ...` | Daftar tujuan **membaca** |

Port 6446 selalu menuju Primary, 6447 menuju salinan. Bila satu router atau node mati, program
mencoba yang berikutnya dalam daftar.

### D. Rahasia bersama: token login (JWT)

Bagaimana poem-service tahu bahwa pengirim puisi sudah login, **tanpa menelepon auth-service setiap kali**?

1. Saat login, auth-service membuat **token**: selembar teks yang berisi identitas pengguna dan
   **tanda tangan** yang dihitung dengan sebuah kunci rahasia.
2. Browser menyimpan token dan menyertakannya di setiap permintaan (`Authorization: Bearer ...`).
3. poem-service memeriksa tanda tangan itu **dengan kunci rahasia yang sama**. Bila cocok, token asli.

Kunci rahasia itu ada di berkas `secrets/jwt_secret.txt`, dibuat sekali oleh
`python3 scripts/siapkan_rahasia.py`, lalu dibagikan Swarm ke kedua layanan sebagai **Docker secret**
(muncul sebagai berkas `/run/secrets/jwt_secret` di dalam container). Karena memakai kunci yang sama,
kedua layanan saling percaya tanpa saling menelepon.

Itulah sebabnya, **bila seluruh klaster auth-db tidak tersedia, pengguna yang sudah punya token masih bisa
mengirim puisi** selama token itu berlaku (satu jam). Yang gagal hanya daftar dan login. Matinya **satu**
server pool `ifham` tidak sampai ke keadaan ini, karena auth-db kini klaster 3 node.

---

## 2. Satu puisi dari awal sampai akhir

Inilah alur lengkap saat seseorang menekan tombol **Kirim** (dari `kontrak/README.md`):

```
 Browser
   | 1. POST /api/puisi  (membawa token)
   v
 Gateway ------------------------------------------------------+
   | 2. meneruskan ke http://poem-service:8080                  |
   v                                                            |
 poem-service                                                   |
   | 3. memeriksa token (kunci jwt_secret)                      |
   | 4. menyimpan puisi (status "diproses") DAN satu baris      |
   |    "event" di database yang sama, dalam SATU transaksi     |
   v                                                            |
 poem-db (lewat router)                                         |
   | 5. poem-service langsung menjawab browser: 202 "diterima"  |
   |                                                            |
 poem-relay (berjalan terus)                                    |
   | 6. mengambil event yang belum terkirim dari database       |
   v                                                            |
 RabbitMQ  (exchange puisi.events, label "puisi.dibuat")        |
   | 7. menyalin pesan ke lima antrean                          |
   v                                                            |
 auto-tagging / klasifikasi-genre / analisis-emosi /            |
 text-to-speech / search-consumer                               |
   | 8. masing-masing mengerjakan bagiannya, lalu menitipkan    |
   |    hasilnya ("puisi.dianalisis" atau "audio.siap")         |
   v                                                            |
 RabbitMQ                                                       |
   | 9. hasil masuk ke q.puisi-hasil dan q.pencarian-indeks     |
   v                                                            |
 poem-consumer  -> menyimpan hasil di poem-db                   |
 search-consumer -> memperbarui indeks pencarian (OpenSearch)   |
                                                                |
 Browser  10. beberapa detik kemudian meminta GET /api/puisi/12 |
          <-- genre, kata kunci, dan audio sudah terisi <--------+
```

Hal yang perlu dipahami dari alur ini:

- **Langkah 4: "satu transaksi".** Puisi dan catatan event disimpan bersamaan. Jadi tidak mungkin puisi
  tersimpan tetapi kabarnya hilang. Pola ini disebut *transactional outbox*.
- **Langkah 5 tidak menunggu RabbitMQ.** Pengguna mendapat jawaban `202` walaupun RabbitMQ sedang
  mati. Kabar dikirim relay begitu RabbitMQ hidup lagi (diuji: skenario 6 `uji_anti_spof.py`).
- **Langkah 7 sampai 9 tidak ditunggu pengguna.** Itu sebabnya halaman menampilkan "Status: diproses"
  lalu berubah menjadi "selesai".
- Puisi dianggap `selesai` setelah dua sumber wajib (`auto-tagging` dan `klasifikasi-genre`) melapor
  (`SUMBER_WAJIB`).
- **Membaca galeri** (`GET /api/puisi`) tidak lewat RabbitMQ. poem-service menjawab dari **Redis** (cache)
  bila ada, dan dari database bila tidak (header `X-Cache-Layer` menunjukkan mana yang menjawab).

---

## 3. Daftar semua sambungan di `stack.yaml`

Bagian `environment:` pada setiap layanan di `stack.yaml` adalah "buku alamat" tadi. Isinya:

| Variabel | Menyambungkan | Contoh isi |
|---|---|---|
| `AMQP_URLS` | layanan ke RabbitMQ | `amqp://puisi:puisi@rabbitmq-1:5672/%2F, ...` |
| `DB_WRITE_HOSTS`, `DB_READ_HOSTS` | poem-service, relay, consumer ke poem-db | `poem-db-router-1:6446, ...` |
| `DB_HOST`, `DB_PORT` | auth-service ke klaster auth-db lewat Router | `auth-db-router`, `6446` |
| `DB_HOST`, `DB_PORT` | text-to-speech ke klaster tts-db lewat Router | `tts-db-router`, `6446` |
| `REDIS_HOSTS`, `REDIS_SENTINELS` | layanan ke Redis; master dicari lewat Sentinel lalu ROLE | `redis-1:6379, ...`, `redis-sentinel-1:26379, ...` |
| `OPENSEARCH_URL` | search-service dan search-consumer ke OpenSearch | `http://opensearch:9200` |
| `S3_ENDPOINT`, `S3_BUCKET` | text-to-speech ke SeaweedFS | `http://seaweedfs:8333`, `audio` |
| `QUEUE` | antrean mana yang dibaca sebuah worker | `q.auto-tagging` |
| `secrets:` | kunci token, sandi database, kunci S3 | `jwt_secret`, `auth_db_password`, ... |
| `networks: [puisi]` | **menaruh layanan di jaringan overlay yang sama** | semua layanan |

Satu-satunya syarat agar sebuah layanan bisa menjangkau layanan lain:

1. Keduanya berada di **jaringan yang sama** (`networks: [puisi]`).
2. Menulis **nama layanan yang benar** (huruf kecil, persis seperti di `stack.yaml`).
3. Port antar-server di Security Group **terbuka** (lihat dokumen 4).
4. Layanan tujuan **sedang hidup**.

---

## 4. Menambah layanan baru (bila suatu hari diperlukan)

Contoh: worker baru yang membaca antrean.

1. **Ada antreannya?** Antrean dideklarasikan sekali di `rabbitmq/definitions.json` (milik Pison):
   nama antrean, jenisnya `quorum`, dan *binding* ke `puisi.events` dengan label yang diminati.
   Consumer cukup membaca, tidak membuat antrean sendiri.
2. **Bangun image-nya** dan unggah ke registry (`skrip/bangun-image.sh`, tambahkan satu baris).
3. **Tambahkan blok di `stack.yaml`:** `image`, `environment` (isi `AMQP_URLS` dan `QUEUE`),
   `networks: [puisi]`, dan `deploy` (`replicas: 2` dengan `max_replicas_per_node: 1`).
4. **Bila ia melayani HTTP** untuk pengunjung, buat satu berkas rute di `gateway/rute/`
   (`set $nama http://nama-layanan:8080; proxy_pass $nama;`) lalu bangun ulang image gateway.
5. Deploy ulang: `docker stack deploy -c deploy/swarm/stack.yaml puisi`.

Itulah yang belum dilakukan untuk worker `gambar-kutipan` (lihat
[`../USULAN-PEMILIK.md`](../USULAN-PEMILIK.md), bagian Ray).

---

## 5. Memeriksa bahwa layanan benar-benar terhubung

Semua perintah dijalankan di **server manager**, setelah deploy.

**a. Apakah nama dikenali?** Container sekali pakai di jaringan yang sama:

```bash
docker run --rm --network puisi_puisi alpine nslookup poem-service
docker run --rm --network puisi_puisi alpine nslookup rabbitmq-2
```

`nslookup` menampilkan alamat (`Address: 10.0.x.x`). Bila muncul `NXDOMAIN`, nama itu salah atau layanan
tidak berjalan.

**b. Apakah layanan menjawab?**

```bash
docker run --rm --network puisi_puisi alpine wget -qO- http://poem-service:8080/sehat
docker run --rm --network puisi_puisi alpine wget -qO- http://auth-service:8080/sehat
```

Jawaban sehat: `{"status":"sukses","pesan":"...sehat."}`. (`auth-service` juga memeriksa
database-nya, jadi bila ia gagal padahal poem-service sehat, periksa `auth-db`.)

**c. Apakah pesan mengalir?** Lihat antrean dan jumlah consumer-nya:

```bash
bash deploy/swarm/skrip/cek.sh
```

Setiap antrean harus punya sedikitnya satu consumer, dan angka pesan menunggu tidak boleh terus naik.

**d. Apa yang dikatakan layanan?** Lihat log dari semua server sekaligus:

```bash
docker service logs --tail 30 puisi_poem-service
docker service logs --tail 30 puisi_auto-tagging
```

**e. Lacak satu puisi.** Setiap permintaan mendapat `X-Request-ID` dari gateway, diteruskan ke
setiap layanan dan ditulis di setiap log. Cari ID itu di log beberapa layanan untuk melihat jalannya.

---

## 6. Gejala dan artinya

| Gejala | Kemungkinan arti |
|---|---|
| Halaman web terbuka, tetapi API menjawab `503 Layanan sedang tidak tersedia` | Gateway tidak bisa menjangkau layanan tujuan: layanan belum hidup, atau **jaringan antar-server terputus** (cek 4789/udp di Security Group) |
| Puisi tetap "diproses" selamanya | Pekerja tidak jalan, atau RabbitMQ bermasalah, atau database tidak bisa ditulis. Lihat `cek.sh` |
| Register dan login gagal, yang lain normal | Klaster `auth-db` (Router atau Primary berpindah) atau auth-service. Beberapa detik gagal saat Primary berpindah itu wajar; bila lebih dari satu menit, jalankan `cek.sh` |
| Pencarian kosong | OpenSearch belum hidup, atau indeksnya belum terbentuk |
| Audio tidak muncul | text-to-speech, tts-db, atau SeaweedFS bermasalah |
| Banyak layanan menunjukkan `Failed` lalu `Starting` berulang pada 10 menit pertama | **Normal.** Swarm tidak punya "tunggu yang lain dulu", jadi layanan mencoba lagi tiap 10 detik sampai dependensinya siap |
