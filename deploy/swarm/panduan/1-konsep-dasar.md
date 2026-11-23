# 1. Konsep dasar: apa yang sebenarnya sedang kita bangun

Dokumen ini ditulis untuk Anda yang **belum pernah memegang microservice, Docker, maupun AWS**.
Tidak ada istilah yang dianggap sudah diketahui. Bacalah pelan-pelan, sekali saja, sebelum
mengikuti [`PANDUAN-DEPLOY-AWS.md`](../../../docs/PANDUAN-DEPLOY-AWS.md).

> **Catatan (23 November 2026):** istilah dan konsep di dokumen ini tetap berlaku. Tetapi **angka dan nama yang menyangkut AWS** ditulis sebelum sandbox diperiksa, dan
> **tidak berlaku** di sandbox kita: server hanya `t3.small` (2 CPU, 2 GiB), **maksimal 9 server**, Amazon Linux 2023 (bukan Ubuntu), tanpa EFS, dan AWS CLI sudah ada di CloudShell.
> Susunan yang dipakai sungguhan ada di [`PANDUAN-DEPLOY-AWS.md`](../../../docs/PANDUAN-DEPLOY-AWS.md) bagian 0; nama pool seperti `pison` hanyalah singkatan pemilik komponen.

Urutan membaca seluruh panduan:

| Urutan | Dokumen | Isinya |
|---|---|---|
| 1 | **Dokumen ini** | Istilah dan gambaran besar |
| 2 | [`2-antar-microservice.md`](2-antar-microservice.md) | Bagaimana bagian-bagian aplikasi saling bicara |
| 3 | [`PANDUAN-DEPLOY-AWS.md`](../../../docs/PANDUAN-DEPLOY-AWS.md) | Langkah praktik dari nol sampai aplikasi berjalan di banyak server (satu-satunya panduan deploy) |
| 4 | [`LAPORAN-EKSPERIMEN-AWS.md`](../../../docs/LAPORAN-EKSPERIMEN-AWS.md) | Apa yang terukur di AWS, temuan, bukti, dan skenario uji mematikan server |

---

## 1. Aplikasinya sendiri

Aplikasi ini adalah **situs puisi**. Pengguna bisa:

- mendaftar dan masuk (login),
- mengirim puisi,
- melihat galeri puisi,
- mencari puisi,
- mendengarkan puisi dibacakan (audio).

Setelah sebuah puisi dikirim, beberapa "pekerja" di belakang layar menganalisisnya: menentukan jenisnya
(pantun, syair, gurindam, atau puisi bebas), mengambil kata kunci, menilai emosinya, dan membuat audionya.

## 2. Monolit dan microservice

**Monolit** = seluruh aplikasi satu paket besar. Seperti satu restoran kecil di mana satu orang
menerima pesanan, memasak, dan mencuci piring. Kalau orang itu sakit, restoran tutup.

**Microservice** = aplikasi dipecah menjadi banyak program kecil, **masing-masing mengerjakan satu hal**.
Seperti restoran besar: ada kasir, koki, tukang cuci piring, dan pengantar makanan. Masing-masing
bisa digandakan sendiri-sendiri (dua koki bila ramai), dan kalau satu orang berhenti, yang lain
tetap bekerja.

Di proyek ini:

| Program kecil (layanan) | Tugasnya, dalam bahasa sehari-hari |
|---|---|
| **gateway** | Pintu depan. Semua pengunjung masuk lewat sini, lalu diarahkan ke layanan yang tepat. Juga menyajikan halaman web |
| **auth-service** | Bagian "daftar dan login". Menerbitkan tanda pengenal (token) |
| **poem-service** | Menerima puisi, menyimpan, dan menampilkan galeri |
| **poem-relay**, **poem-consumer** | Kurir internal: mengirim kabar "ada puisi baru" dan menerima hasil analisis |
| **auto-tagging**, **klasifikasi-genre**, **analisis-emosi**, **text-to-speech** | Pekerja yang menganalisis puisi di belakang layar |
| **search-service**, **search-consumer** | Bagian pencarian |
| **RabbitMQ** | "Kantor pos": tempat pesan antar-layanan dititipkan dan diantre |
| **Database** (poem-db, auth-db, tts-db) | Lemari arsip tempat data disimpan permanen |
| **Redis** | Catatan sementara di meja (cache) supaya jawaban lebih cepat |
| **OpenSearch** | Mesin pencari |
| **SeaweedFS** | Lemari penyimpanan berkas audio |

## 3. Container, image, dan Docker

- **Container** = satu program yang dibungkus lengkap dengan semua yang dibutuhkannya, berjalan
  terisolasi. Bayangkan kotak bekal: lauk, nasi, dan sendoknya sudah ada di dalamnya.
- **Image** = "resep beku" untuk membuat container. Satu image bisa dijalankan menjadi banyak container.
- **Docker** = program yang membuat dan menjalankan container.
- **Docker Compose** = alat untuk menjalankan banyak container sekaligus di **satu** komputer
  (inilah yang selama ini Anda pakai di laptop: `docker compose up`).
- **Registry** = tempat menyimpan image supaya komputer lain bisa mengunduhnya (seperti toko aplikasi).
  Docker Hub adalah registry publik. ECR adalah registry milik AWS.

## 4. Mengapa satu server saja tidak cukup

Bila seluruh aplikasi berjalan di **satu komputer** dan komputer itu mati, semuanya mati. Titik
yang kalau gagal membuat semuanya berhenti disebut **SPOF** (*Single Point of Failure*, "satu titik
kegagalan").

Tugas kuliah ini meminta sistem yang **tahan gagal**: bila satu server mati, aplikasi tetap melayani.
Caranya: pakai **beberapa server**, dan setiap bagian penting punya **cadangan di server yang berbeda**.

> Dua container di server yang sama **tidak** melindungi dari matinya server. Cadangan harus berada
> di komputer lain.

## 5. AWS dan istilahnya

**AWS** (Amazon Web Services) menyewakan komputer lewat internet. Anda tidak membeli komputer; Anda
menyewa dan membayar (atau memakai kredit sandbox) selama dipakai.

| Istilah | Artinya sederhana | Di proyek ini |
|---|---|---|
| **Sandbox** | Akun AWS latihan dengan batasan, biasanya dari kampus | Tempat kita bereksperimen |
| **Console** | Situs web untuk mengatur AWS dengan klik | Dipakai untuk hampir semua langkah |
| **Region** | Lokasi fisik pusat data AWS (satu kota/negara) | Di sandbox Anda tidak bisa dipilih. Pakai yang tertulis di pojok kanan atas console |
| **Availability Zone (AZ, zona)** | Gedung pusat data terpisah di dalam satu region. Satu gedung bisa mati tanpa mengganggu gedung lain | Tiga server pertama tiap microservice kita taruh di zona berbeda |
| **EC2** | Layanan penyewaan komputer virtual | Setiap "server" kita adalah satu EC2 |
| **Instance** | Satu komputer virtual EC2 | `puisi-1`, `puisi-2`, `puisi-3` |
| **Instance type** | Ukuran komputer (`t3.small` = 2 CPU, 2 GiB memori) | Di sandbox hanya sampai `t3.small` |
| **AMI** | "Sistem operasi awal" komputer | Amazon Linux 2023 (AMI harus milik Amazon) |
| **Key pair** | Kunci untuk masuk ke server lewat SSH (berkas `.pem`) | Simpan baik-baik |
| **SSH** | Cara masuk ke terminal server dari jauh | Atau pakai tombol Connect di browser |
| **VPC** | Jaringan pribadi Anda di dalam AWS | Bawaan, tidak perlu diubah |
| **Subnet** | Potongan VPC yang berada di satu zona | Dipilih saat membuat server, agar zonanya berbeda |
| **Security Group** | Pagar/firewall: daftar "pintu" (port) yang boleh dimasuki dan dari mana | Kita buat dua |
| **Port** | Nomor pintu sebuah program (web = 80, SSH = 22) | Dibuka seperlunya saja |
| **Load Balancer (ALB)** | Penerima tamu tunggal yang membagi pengunjung ke beberapa server yang sehat | Satu alamat untuk semua server pool `pison` (tempat gateway) |
| **Target group** | Daftar server di belakang load balancer dan cara memeriksa kesehatannya | Dipakai oleh ALB |
| **ECR** | Registry image milik AWS | Tidak dipakai; registry sendiri di Swarm |
| **IAM, role, instance profile** | Pengaturan "siapa boleh melakukan apa" di AWS. Instance profile menempelkan izin ke sebuah server | Dipakai bila server perlu mengakses ECR |
| **AWS CLI** | Program perintah (teks) untuk mengatur AWS tanpa klik | Sudah terpasang di CloudShell; semua langkah deploy memakainya |

## 6. Docker Swarm: menyatukan banyak server

**Docker Swarm** menghubungkan beberapa komputer menjadi **satu klaster** yang bisa diperintah sebagai
satu kesatuan. Anda cukup berkata "jalankan 2 salinan poem-service", dan Swarm yang memilih komputer
mana dan menyalakan ulang bila ada yang mati.

| Istilah Swarm | Artinya sederhana |
|---|---|
| **Node** | Satu server yang bergabung ke Swarm |
| **Manager** | Node yang boleh memberi perintah dan mengambil keputusan. Kita jadikan **tiga server di zona berbeda** sebagai manager (butuh mayoritas: 2 dari 3 harus hidup) |
| **Worker** | Node pekerja: menjalankan layanan tetapi tidak ikut memutuskan. **Server aplikasi kita** adalah worker, jumlahnya bebas |
| **Service** | Satu jenis pekerjaan yang dijaga Swarm tetap berjalan (mis. `poem-service`) |
| **Replica** | Salinan sebuah service. `replicas: 2` = dua salinan. **Mode global** = tepat satu salinan di setiap node yang cocok: menambah server menambah salinan otomatis |
| **Task** | Satu salinan yang sedang berjalan di satu node |
| **Stack** | Sekumpulan service yang dideploy bersama dari satu berkas (`stack.yaml`) |
| **Overlay network** | Jaringan virtual yang menghubungkan container di server **berbeda** seolah satu jaringan |
| **Label** dan **constraint** | Label = stiker di node (`puisi.pool.puisi=true`, `puisi.slot=1`). Constraint = aturan "service ini hanya boleh di node berstiker itu" |
| **Secret** dan **config** | Cara aman membagikan sandi (secret) dan berkas pengaturan (config) ke semua node |
| **Job** | Tugas yang dijalankan sekali sampai selesai (membentuk klaster database) |

## 7. Gambaran besar yang akan Anda bangun

```
                        Pengunjung (browser)
                               |
                               v
                  [ Load Balancer (ALB) ]   <- satu alamat, membagi tamu
                  /          |          \
                 v           v           v
        +-------------+ +-------------+ +-------------+
        | POOL PISON  | | POOL PISON  | | POOL PISON  |   <- gateway, RabbitMQ (3), Redis,
        | server 1    | | server 2    | | server 3    |      auto-tagging  (Pison)
        +------+------+ +------+------+ +------+------+
               \_______________|_______________/
                               |   jaringan overlay Swarm: semua layanan saling memanggil lewat nama
        +-------------+ +-------------+ +-------------+
        | POOL RIDLO  | | POOL RIDLO  | | POOL RIDLO  | + server tambahan   <- poem-service, relay, consumer,
        | slot 1      | | slot 2      | | slot 3      |   (tanpa data)         genre, poem-db (3 anggota)
        +-------------+ +-------------+ +-------------+
        +-------------+ +-------------+ +-------------+
        | POOL IFHAM  | | POOL IFHAM  | | POOL IFHAM  | + server tambahan   <- auth, auth-db (3), tts, tts-db (3),
        | slot 1      | | slot 2  *   | | slot 3      |                        SeaweedFS (* satu salinan)
        +-------------+ +-------------+ +-------------+
        +-------------+ +-------------+ +-------------+
        | POOL EVAN   | | POOL EVAN   | | POOL EVAN   | + server tambahan   <- pencarian, OpenSearch (3 anggota)
        | slot 1      | | slot 2      | | slot 3      |
        +-------------+ +-------------+ +-------------+
        +-------------+ +-------------+
        | POOL RAY    | | POOL RAY    |                                     <- analisis-emosi
        +-------------+ +-------------+
```

(Gambar di atas hanya **ilustrasi**. Penempatan pastinya ada di komentar paling atas `stack.yaml`.)

Satu kelompok server (**pool**) untuk **setiap microservice**. Gambar di atas memakai pembagian **per pemilik** (14 server);
bila sandbox mengizinkan, tiap microservice dipisah lagi (21 server, lihat tabel di [`../README.md`](../README.md)). Manfaatnya:

- **Kegagalan terkurung.** Server pool Ridlo mati: auth, pencarian, dan audio tidak tersentuh, karena layanan
  mereka tidak ada di server itu.
- **Tiap microservice bertumbuh sendiri.** Pool Ridlo boleh 3, 5, atau 10 server tanpa menyentuh pool lain.
  Setiap server tambahan otomatis mendapat satu salinan layanan Ridlo.
- **Kepemilikan jelas.** Server, data, dan layanan satu pemilik berada di satu tempat.

Batasnya: tiap klaster memakai **suara mayoritas**, jadi anggota klaster tetap **tiga** (slot 1, 2, 3).
Server tambahan di sebuah pool menambah salinan layanan, **bukan** anggota klaster, jadi tidak menambah
ketahanan data.

Bintang (`*`) menandai komponen yang **masih hanya satu salinan** (SeaweedFS untuk audio). Bila server
yang memegangnya mati, fitur audio berhenti. Redis (cache) juga satu salinan, tetapi hanya membuat
aplikasi lebih lambat, bukan berhenti. Ini **bukan** kesalahan Anda; lihat
[`../USULAN-PEMILIK.md`](../USULAN-PEMILIK.md).

## 8. Apa yang dijamin dan tidak dijamin

| Hal | Status |
|---|---|
| Berkas konfigurasi (`stack.yaml`) sintaksnya benar dan diterima Swarm | Sudah diperiksa |
| Semua layanan benar-benar hidup dan saling terhubung di banyak server AWS | **Belum pernah dicoba.** Anda yang akan pertama menjalankannya |
| Aplikasi tetap hidup saat satu server mati | **Belum diuji di AWS.** Klaster database (failover) dan klaster pencarian sudah diuji di Docker Compose satu mesin. Diperkirakan semuanya bertahan kecuali audio |
| "Bebas SPOF" | **Tidak boleh diklaim.** Masih ada SeaweedFS (audio) dan Redis (cache), dan tiga server per klaster hanya menahan satu kegagalan |

Karena belum pernah dijalankan di AWS, **kemungkinan Anda menemukan masalah yang belum kami
ketahui**. Itu wajar. Catat apa yang terjadi, dan jangan menyembunyikan hasil yang tidak sesuai
harapan: laporan yang jujur lebih bernilai daripada laporan yang "mulus".

## 9. Kebiasaan aman (penting sejak awal)

- Jangan membuka port database, RabbitMQ, atau Redis ke internet. Sandi bawaannya (`poem/poem`, `puisi/puisi`)
  sudah tertulis di repositori.
- Jangan menyimpan berkas `.pem`, kunci AWS, atau isi folder `secrets/` ke GitHub.
- Matikan atau hapus server yang tidak dipakai. Server yang menyala memakai kredit.
- Bila ragu pada sebuah langkah, berhenti dan baca lagi. Hampir semua langkah di sini bisa diulang
  dari awal tanpa merusak apa pun, karena hanya menyewa server sementara.
