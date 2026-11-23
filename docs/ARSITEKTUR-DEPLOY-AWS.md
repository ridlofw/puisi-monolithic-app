# Arsitektur Deploy di AWS Sandbox

Dokumen ini menjelaskan **bentuk sistem yang benar-benar berjalan** di AWS pada 23 November 2026, dan **kenapa bentuknya begitu**: kenapa 9 server, kenapa layanan digabung di server yang sama,
dan bagaimana server saling berhubungan. Langkah membuatnya ada di [`PANDUAN-DEPLOY-AWS.md`](PANDUAN-DEPLOY-AWS.md); cerita eksperimennya di [`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md).

Setiap pernyataan diberi label: **[terukur]** dibaca dari sistem yang berjalan, **[terbukti]** diuji dan hasilnya tercatat, **[hitungan]** dihitung dari angka terukur,
**[aturan]** tertulis di aturan lab tetapi tidak saya uji, **[prediksi]** diperkirakan dari rancangan dan belum diuji.

---

## 1. Ringkasan

```
                         Pengunjung (browser)
                                 | HTTPS
                          +------v-------+
                          |  CloudFront  |  satu alamat dxxxx.cloudfront.net
                          +--+---+----+--+
          halaman/JS/CSS     |   |    |  /fungsi*
          /latar*.jpeg       |   |    +-------------------> Lambda (gambar kutipan)
                +------------+   | /api/*  /audio/*
                v                v  HTTP 80
               S3        +-------+--------+
                         |      ALB       |  3 zona, health check /healthz
                         +--+----+----+---+
                            |    |    |  port 80 (gateway, mode host)
                         zona a zona b zona c
                         +----+ +----+ +----+
   KELOMPOK A (manager)  | s1 | | s2 | | s3 |  gateway, RabbitMQ 1/2/3, OpenSearch 1/2/3 + HAProxy,
   infra + pencarian +   +----+ +----+ +----+  auto-tagging, analisis-emosi, search-service,
   analisis                                    search-consumer, Redis (s2), registry (s1)
                         +----+ +----+ +----+
   KELOMPOK B (worker)   | s4 | | s5 | | s6 |  poem-db 1/2/3 (+router di s4, s5), poem-service,
   puisi + genre         +----+ +----+ +----+  relay, consumer, klasifikasi-genre
                         +----+ +----+ +----+
   KELOMPOK C (worker)   | s7 | | s8 | | s9 |  auth-db 1/2/3, tts-db 1/2/3, router, auth-service,
   auth + suara          +----+ +----+ +----+  SeaweedFS (s7), text-to-speech (s8 saat diukur)
```

Lima poin:

1. **9 server `t3.small`** (2 vCPU, 2 GiB), tiga kelompok × tiga zona (a, b, c). Server nomor `N` dari tiap kelompok berada di zona yang sama (a: s1, s4, s7; b: s2, s5, s8; c: s3, s6, s9).
2. **Setiap klaster berdata punya tiga anggota, satu per zona** (MySQL poem/auth/tts, RabbitMQ, OpenSearch). Matinya satu server atau satu zona menghilangkan paling banyak satu anggota tiap klaster, jadi kuorum bertahan.
3. **Tiga server pertama adalah manager Swarm** dan menjalankan gateway (target ALB). Server data (s4 sampai s9) adalah worker.
4. **Pembagian "8 kelompok layanan" menjadi 3 kelompok server** diputuskan dari memori dan zona (bagian 3), bukan dari siapa pemilik komponennya.
5. **Angka 9 adalah batas efektif akun ini.** API EC2 menerima peluncuran lebih dari 9, tetapi sistem lab menghentikan kelebihannya dalam ± 10 detik, di region mana pun (bagian 2). Itu juga mendekati kebutuhan memori minimum.

---

## 2. Kenapa 9 instance? Berapa maksimalnya?

### 2.1 Jawaban singkat
**Maksimal 9 instance berjalan bersamaan untuk seluruh akun, dan batas itu ditegakkan oleh sistem lab, bukan oleh AWS.** API EC2 menerima peluncuran lebih dari 9, tetapi kelebihannya
**dihentikan sistem lab dalam sekitar 10 detik sampai 1 menit**. Jadi 10, 12, atau 38 instance **tidak bisa dipertahankan**, dan menambah region tidak membantu. **[terbukti]**

### 2.2 Tiga pengujian pada 23 November 2026
| # | Pengujian | Hasil | Bukti |
|---|---|---|---|
| 1 | 15:47 UTC: peluncuran instance ke-10 (`t3.nano`) saat 9 berjalan | **Diterima.** Saya menghapusnya sendiri dalam beberapa detik, jadi tidak sempat melihat apa yang terjadi bila dibiarkan | [`uji-instance-ke-10.log`](bukti-aws/log-cloudshell/uji-instance-ke-10.log), [`26-...jpg`](bukti-aws/26-percobaan-instance-ke-10-berhasil-dibuat.jpg) |
| 2 | 16:03 UTC: 29 peluncuran `t2.nano` berurutan sampai total **38** instance (45 vCPU), lalu pembersihan | **Semua 29 diterima API.** Tetapi 26 di antaranya sudah berstatus `terminated` (`User initiated`) **sebelum pembersihan saya**, dihentikan antara 10 detik dan 1 menit setelah peluncuran; hanya 3 yang saya hapus. CloudTrail: **39** panggilan `TerminateInstances` oleh **pengguna sistem lab** (`sys...`) dan 1 oleh sesi saya. Sembilan server asli tidak tersentuh | [`uji-batas-instance.log`](bukti-aws/log-cloudshell/uji-batas-instance.log), [`uji-batas-pelaku.log`](bukti-aws/log-cloudshell/uji-batas-pelaku.log) |
| 3 | 16:07 UTC: satu `t2.nano` di **`us-west-2`** saat 9 berjalan di `us-east-1` | **Dihentikan 9 detik setelah diluncurkan** (perintah penghentian saya baru jalan ± 2 menit kemudian). Batasnya per **akun**, bukan per region | [`uji-batas-region.log`](bukti-aws/log-cloudshell/uji-batas-region.log), [`27-...jpg`](bukti-aws/27-uji-batas-region-dihentikan-9-detik.jpg) |

### 2.3 Batas berlapis
| Lapisan | Batas | Label |
|---|---|---|
| Jenis instance | hanya `t2` dan `t3` sampai `small`; `t3.medium` dan `t3.large` **ditolak AWS** (`UnauthorizedOperation`); `t3.nano`, `t3.small`, `t2.micro`, `t2.small` diizinkan | **[terbukti]** ([`uji-tipe-instance.log`](bukti-aws/log-cloudshell/uji-tipe-instance.log), [`analisis-batas.log`](bukti-aws/log-cloudshell/analisis-batas.log)) |
| Jumlah instance di API EC2 | **tidak ada penolakan sampai 38 instance (45 vCPU)**. Jadi kuota "32 vCPU" dan atribut akun `max-instances` = 20 tidak mengikat di API | **[terbukti]** |
| Jumlah instance yang bertahan | **9 per akun** (lintas region); kelebihan dihentikan oleh pengguna sistem lab dalam ± 10 detik sampai 1 menit; yang dihentikan adalah peluncuran **baru**, sembilan server asli dibiarkan | **[terbukti]**; cara kerja pemantau di dalam lab tidak diketahui |
| Aturan tertulis | Readme lab: 9 instance, region `us-east-1` dan `us-west-2`, 32 vCPU | **[aturan]**; tangkapan layarnya belum dilampirkan |
| Anggaran | $40; terpakai sekitar $2,5 (penghitung lab tertinggal 8 sampai 12 jam); 9 `t3.small` ≈ $0,19 per jam menurut tarif standar (tidak diverifikasi) | **[terukur]** |

Peluncuran instance yang akan dihentikan tetap menimbulkan biaya sangat kecil (29 `t2.nano` selama kurang dari 1,5 menit). Tidak ada tanda akun ditandai atau dikunci sesudah uji ini, tetapi **konsekuensi jangka panjang melanggar batas tidak saya ketahui**,
dan pengujian ini sebaiknya tidak diulang.

### 2.4 Kenapa 9 tetap tepat untuk rancangan ini
1. **Itu batas efektifnya.** Tidak ada cara mempertahankan lebih dari 9.
2. **9 juga mendekati kebutuhan minimum.** Pemakaian memori terukur dengan 38 layanan (sesudah satu uji ujung ke ujung): s1 sampai s3 **3516 MB**, s4 sampai s6 **3482 MB**, s7 sampai s9 **4207 MB**, jumlah **11 205 MB**
   dari 17 181 MB (9 × 1909 MB), yaitu **65%** **[terukur]**. Bila jumlah server diubah dengan beban yang sama **[hitungan kasar; overhead tetap per server membuat total sedikit lebih kecil bila servernya lebih sedikit]**:

   | Jumlah server `t3.small` | RAM total | Pemakaian | Kesimpulan |
   |---|---|---|---|
   | 3 | 5 727 MB | 196% | mustahil |
   | 6 | 11 454 MB | 98% | tanpa sisa untuk cache dan lonjakan; swap menghancurkan performa |
   | 7 | 13 363 MB | 84% | sangat ketat |
   | **9** | **17 181 MB** | **65%** | dipakai; server 7 sampai 9 sudah ketat (tersedia 267 sampai 426 MB) |

3. **Kuorum menuntut tiga anggota per klaster**, dan tiga zona menuntut tiga server per kelompok. Tiga kelompok × tiga zona = 9.

### 2.5 Bagaimana menskalakan seluruh proyek bila instance dibatasi 9?
Skala horizontal berbasis instance mentok di 9. Skala lebih lanjut harus lewat cara yang **tidak menambah instance EC2**:

| Cara | Efek | Status |
|---|---|---|
| Halaman, JS, CSS dari S3 + CloudFront | server tidak melayani berkas statis; skala otomatis | **terbukti** (CloudFront dua jalur) |
| Lambda untuk gambar kutipan | skala otomatis, tidak terhitung instance | **terbukti** |
| Layanan terkelola yang tidak terhitung sebagai instance: RDS, ElastiCache, DynamoDB, SQS, SNS | memindahkan 9 node MySQL (± 4 GB dari 11 GB terpakai) atau Redis keluar dari 9 server membebaskan memori untuk replika lain | API dapat **dibaca**; **membuatnya belum diuji**. RabbitMQ memakai AMQP, jadi SQS menuntut perubahan kode. `mq`, `es` (OpenSearch Service), `ecs`, `efs` **ditolak** |
| Menambah replika layanan tanpa data di 9 server yang ada | menambah kapasitas sampai memori habis (sisa 267 sampai 629 MB per server) | belum diuji; terbatas memori |
| Mengatur ulang penempatan (mis. worker suara ke kelompok B) | meratakan memori | belum dicoba |
| Auto Scaling Group | **tidak membantu**: kelebihan di atas 9 dihentikan | **terbukti** oleh pengujian 2 |
| Server lebih besar | **tidak mungkin** (maksimal `small`) | **terbukti** |
| Region atau akun lain | **tidak membantu** untuk akun ini (batas lintas region) | **terbukti** pengujian 3 |

Kesimpulan jujur: dalam sandbox ini, "scalable" berarti **mengisi 9 server sebaik-baiknya dan memindahkan beban ke layanan serverless atau terkelola yang diizinkan**, bukan menambah server. Percobaan berikutnya yang paling bernilai:
membuat satu RDS MySQL kecil dan satu antrean SQS untuk melihat apakah pembuatannya diizinkan (hanya pembacaannya yang terbukti).

---

## 3. Kenapa layanan digabung begini?

### 3.1 Dari 21 ke 14 ke 9
`stack.yaml` dirancang dengan **satu kelompok server (pool) per microservice**, dikendalikan label `puisi.pool.<kunci>=true`. Ada delapan kunci pool:

| Kunci pool | Isi | Pemilik |
|---|---|---|
| `infra` | gateway, RabbitMQ (3), Redis | Pison |
| `auto-tagging` | auto-tagging | Pison |
| `puisi` | poem-service, relay, consumer, poem-db (3) + router | Ridlo |
| `genre` | klasifikasi-genre | Ridlo |
| `auth` | auth-service, auth-db (3) + router | Ifham |
| `tts` | text-to-speech, tts-db (3) + router, SeaweedFS | Ifham |
| `pencarian` | search-service, search-consumer, OpenSearch (3) + HAProxy | Evan |
| `emosi` | analisis-emosi | Ray |

Dipisah penuh: **21 server**; per pemilik: **14 server** (pison, ridlo, ifham, evan, ray). Di akun biasa itu bisa dipilih. Di sandbox kita hanya punya 9, sehingga **satu server membawa beberapa label pool sekaligus**.
Penggabungan diputuskan dengan tiga aturan:

1. **Tiap klaster berdata tetap tiga anggota di tiga zona.** Kelompok yang memegang klaster harus tiga server.
2. **Gabungkan pool yang ringan ke kelompok yang sisa memorinya paling banyak.** Pada pengukuran 23 layanan, server infra memakai hanya 502 sampai 538 MB (sisa ± 1,4 GiB), server data 930 sampai 1066 MB.
3. **Jaga pemisahan kegagalan:** jalur data utama (puisi) tidak berbagi server dengan pool lain, supaya masalah pencarian atau suara tidak menyentuh puisi.

### 3.2 Hasilnya
| Kelompok | Server | Pool yang dibawa | Kenapa digabung begitu |
|---|---|---|---|
| **A** | s1, s2, s3 | `infra` + `auto-tagging` + `emosi` + `pencarian` | Gateway harus ada di tiga zona karena ALB menunjuk ke situ. RabbitMQ perlu tiga node. Worker `auto-tagging` dan `emosi` ringan dan tanpa data. OpenSearch butuh tiga node dan hanya muat di kelompok yang memorinya paling longgar. Tiga manager Swarm ditaruh di sini (ganjil, tiga zona) |
| **B** | s4, s5, s6 | `puisi` + `genre` | Klaster poem-db (jalur data paling penting) dengan empat layanan Ridlo; tidak berbagi dengan pool lain |
| **C** | s7, s8, s9 | `auth` + `tts` | Dua klaster MySQL kecil (auth-db, tts-db), auth-service, dan layanan suara (milik pemilik yang sama). Gabungan ini yang **paling ketat** |

**Evaluasi sesudah diukur (jujur):** gabungan `auth` + `tts` ternyata paling berat (s7 sampai s9: tersedia 267 sampai 426 MB, swap sampai 397 MB), sedangkan kelompok B masih tersedia 516 sampai 629 MB. Pada 9 server, **memindahkan worker suara
dan SeaweedFS ke kelompok B** akan menyeimbangkan memori **[prediksi, belum dicoba]**. Pilihan awal didasarkan pada pemilik komponen dan pengukuran 23 layanan; pengukuran 38 layanan baru ada sesudah tahap 2.

### 3.3 Dua jenis penempatan
| Jenis | Aturan | Contoh |
|---|---|---|
| **Dipaku ke satu server** (layanan berdata) | `pool` **dan** `slot` (1, 2, 3). Slot `N` berarti anggota klaster ke-`N`, di server berzona `N` | poem-db-1..3, auth-db-1..3, tts-db-1..3, rabbitmq-1..3, opensearch-1..3, poem-db-router-1 dan -2; SeaweedFS (`puisi.audio=true`) |
| **Satu salinan per server pool** (`mode: global`) | hanya `pool` | gateway, poem-service, relay, consumer, auth-service, auto-tagging, genre, emosi, HAProxy OpenSearch |
| **Bebas, jumlah tetap** (`replicas`) | `pool`, Swarm memilih server | Redis (1), search-service (2), search-consumer (1), text-to-speech (1), auth-db-router (2), tts-db-router (2, maksimal 1 per server), registry (dipaku slot 1) |

Dari `stack.yaml`, tiga layanan `global` dijadikan `replicas` oleh [`override-9server.yaml`](../deploy/aws/override-9server.yaml) supaya hemat memori di server 2 GiB.

---

## 4. Penempatan yang sebenarnya (dibaca dari klaster)

Diambil dengan `docker service ps` pada 23 November 2026 sekitar 15:50 UTC **[terukur]**; berkas mentah: [`penempatan-layanan.txt`](bukti-aws/log-cloudshell/penempatan-layanan.txt).

| Server | Zona | Peran Swarm | Layanan yang berjalan |
|---|---|---|---|
| **s1** | a | **manager (Leader)** | gateway, RabbitMQ-1, OpenSearch-1, HAProxy OpenSearch, opensearch-replika, search-consumer, auto-tagging, analisis-emosi, **registry** |
| **s2** | b | manager | gateway, RabbitMQ-2, OpenSearch-2, HAProxy OpenSearch, **Redis**, search-service, auto-tagging, analisis-emosi |
| **s3** | c | manager | gateway, RabbitMQ-3, OpenSearch-3, HAProxy OpenSearch, search-service, auto-tagging, analisis-emosi |
| **s4** | a | worker | poem-db-1, poem-db-router-1, poem-service, relay, consumer, klasifikasi-genre |
| **s5** | b | worker | poem-db-2, poem-db-router-2, poem-service, relay, consumer, klasifikasi-genre |
| **s6** | c | worker | poem-db-3, poem-service, relay, consumer, klasifikasi-genre |
| **s7** | a | worker | auth-db-1, tts-db-1, auth-db-router, tts-db-router, auth-service, **SeaweedFS** |
| **s8** | b | worker | auth-db-2, tts-db-2, auth-db-router, auth-service, **text-to-speech** |
| **s9** | c | worker | auth-db-3, tts-db-3, tts-db-router, auth-service |

Total 56 task. (Label manager dibaca dari `docker node ls`: satu Leader, dua Reachable, enam Ready.) Server tempat layanan "bebas" bukan jaminan: Swarm dapat memindahkannya bila server mati
(misalnya replika kedua `tts-db-router` dibuat ulang di server lain selama sesi ini).

---

## 5. Hubungan antar-instance

### 5.1 Jaringan
| Hal | Keadaan | Label |
|---|---|---|
| VPC dan subnet | VPC bawaan; satu subnet bawaan per zona (a, b, c) | **[terbukti]** (`9server.sh luncurkan`) |
| Security Group `puisi-swarm-sg` | **semua** lalu lintas hanya dari anggota grup itu sendiri; **tidak ada** aturan masuk dari internet (tanpa SSH; kendali lewat SSM) | **[terbukti]** |
| Security Group `puisi-alb-sg` | TCP 80 dari mana saja; `puisi-swarm-sg` mengizinkan TCP 80 dari grup ini | **[terbukti]** (`alb.sh`) |
| Keluar | terbuka (menarik image, model suara dari huggingface.co, API AWS) | **[terukur]** |
| Swarm | 3 manager (Raft), gossip dan overlay antar-server (port 2377, 7946, 4789 di dalam Security Group) | **[terbukti]** |
| Jaringan overlay `puisi_puisi` | satu jaringan untuk semua layanan; **tidak dienkripsi** (butuh protokol ESP di Security Group); nama layanan menjadi DNS | **[terbukti]** |
| Registry | satu salinan di s1, port 5000 lewat routing mesh; semua server menarik image dari `localhost:5000` | **[terbukti]** |

### 5.2 Siapa memanggil siapa
| Dari | Ke | Untuk apa | Protokol / port |
|---|---|---|---|
| Browser | CloudFront | semua | HTTPS 443 |
| CloudFront | S3 website; Lambda; ALB | halaman; gambar kutipan; `/api` dan `/audio` | HTTP 80; HTTPS; HTTP 80 |
| ALB | gateway di **s1, s2, s3** | semua permintaan aplikasi; health check `/healthz` | HTTP 80 (mode host) |
| gateway | auth-service (s7 sampai s9) | login, daftar | HTTP 8080 (VIP overlay) |
| gateway | poem-service (s4 sampai s6) | baca dan kirim puisi | HTTP 8080 |
| gateway | search-service (2 replika di s2, s3) | pencarian | HTTP 8080 |
| gateway | SeaweedFS (s7) | berkas audio `/audio/...` | HTTP 8333 (S3) |
| poem-service, consumer | poem-db-router → anggota PRIMARY poem-db (s4 sampai s6) | tulis dan baca puisi | MySQL 6446 → 3306 |
| auth-service | auth-db-router → PRIMARY auth-db (s7 sampai s9) | akun | MySQL 6446 → 3306 |
| relay (s4 sampai s6) | RabbitMQ (s1 sampai s3) | menerbitkan peristiwa dari tabel outbox | AMQP 5672 |
| RabbitMQ | auto-tagging, analisis-emosi, search-consumer (s1 sampai s3); klasifikasi-genre dan poem-consumer (s4 sampai s6); text-to-speech (s8) | tugas analisis dan hasilnya | AMQP 5672 (antrean quorum 3 replika) |
| text-to-speech | SeaweedFS (s7); tts-db-router | menyimpan audio; mencatat pekerjaan | HTTP 8333; MySQL 6446 |
| search-service, search-consumer | HAProxy `opensearch` → opensearch-1..3 (s1 sampai s3) | indeks dan cari | HTTP 9200 (antar node OpenSearch 9300) |
| search-service dan search-consumer | Redis (s2) | cache | 6379 |
| manager (s1 sampai s3) | semua server | kendali Swarm | 2377, 7946, 4789 |

(Nama alamat persis ada di `stack.yaml`.)

### 5.3 Alur satu puisi
1. Browser memuat halaman dari S3 (lewat CloudFront), lalu memanggil `POST /api/puisi` → CloudFront → ALB → **gateway** (salah satu dari s1 sampai s3) → **poem-service** (s4 sampai s6) menulis puisi **dan** satu baris peristiwa (outbox) dalam satu transaksi ke **poem-db** (PRIMARY di s4 sampai s6). Pengunjung menerima `202`.
2. **relay** mengirim peristiwa ke **RabbitMQ** (s1 sampai s3).
3. Para pekerja mengambil tugasnya dari antrean masing-masing: **auto-tagging** (tag), **klasifikasi-genre** (genre), **analisis-emosi** (emosi), **search-consumer** (indeks ke OpenSearch), **text-to-speech** (suara ke SeaweedFS di s7).
4. Hasil analisis dikirim balik lewat RabbitMQ ke **poem-consumer** (s4 sampai s6), yang menggabungkannya ke baris puisi; `url_audio` diisi saat peristiwa `audio.siap` tiba.
5. Pengunjung memuat ulang galeri: daftar dari `GET /api/puisi` memuat tag, genre, emosi, dan `url_audio`; audio diambil lewat `/audio/...` → ALB → gateway → SeaweedFS.

---

## 6. Ketahanan: apa yang bertahan bila ada yang mati

Kuorum: Swarm manager 3 (menahan 1 mati), MySQL InnoDB 3 (1), RabbitMQ quorum 3 (1), OpenSearch 3 pengelola (1). Dua server dari kelompok yang sama mati berarti klaster kelompok itu kehilangan kuorum.

| Kejadian | Yang terjadi | Label |
|---|---|---|
| **s4 mati** (PRIMARY poem-db-1, 1 dari 3 poem-service) | 0 dari 258 probe lewat ALB gagal; PRIMARY pindah ke poem-db-3; penulisan tetap berhasil; pulih dan bergabung ± 100 detik | **[terbukti]**, tetapi saat baru **23 layanan** |
| s1 mati (manager Leader, gateway, RabbitMQ-1, OpenSearch-1, **registry**) | Raft 2 dari 3; gateway 2 dari 3 lewat ALB; RabbitMQ 2 dari 3; OpenSearch kuning. **Registry hilang**: layanan yang sudah berjalan tidak terganggu, tetapi image baru tidak bisa ditarik sampai s1 pulih | **[prediksi]** |
| s7 mati (SeaweedFS, auth-db-1, tts-db-1) | **audio berhenti** (SeaweedFS satu proses, SPOF); login tetap lewat 2 anggota auth-db | **[prediksi]** |
| s8 mati (text-to-speech) | antrean TTS menumpuk sampai Swarm menjadwalkan ulang worker di server berlabel `tts` | **[prediksi]** |
| Satu zona mati (s1, s4, s7) | tiap klaster kehilangan satu anggota, kuorum bertahan; audio berhenti | **[prediksi, tidak diuji]** |
| Dua server satu kelompok (mis. s4 dan s5) | penulisan puisi gagal (kuorum poem-db hilang) | **[prediksi]** |

Skenario uji yang belum dijalankan ada di [`LAPORAN-EKSPERIMEN-AWS.md`](LAPORAN-EKSPERIMEN-AWS.md) bagian 7.

---

## 7. Titik tunggal dan batas

- **SeaweedFS** satu proses di satu server (s7): audio berhenti bila server itu mati. EFS tidak ada di sandbox.
- **Registry** satu salinan di s1; **Redis** satu salinan (cache); **text-to-speech** satu replika.
- **ALB** terbuka lewat HTTP langsung; **overlay tidak dienkripsi**; kata sandi database bawaan ada di `stack.yaml` (ganti sebelum dipakai di luar sandbox).
- **s7 sampai s9 paling ketat** (bagian 3.2). `t3` adalah tipe burstable; perilaku di bawah beban banyak pengguna **belum diukur**.
- **Tidak bisa ditambah server**: batas 9 per akun ditegakkan sistem lab (bagian 2.5 memuat jalur skala lain).
- Semua hilang saat timer lab habis; arsitektur ini harus dibuat ulang tiap sesi (panduan).

---

## 8. Keputusan dan alternatif yang ditolak

| Keputusan | Alternatif | Kenapa begini |
|---|---|---|
| 9 server `t3.small` | `t3.large` (8 GiB) | ditolak AWS **[terbukti]** |
| Docker Swarm | ECS/EKS | tidak ada di sandbox |
| Registry sendiri di Swarm | ECR | pembuatan ECR tidak diuji; registry sendiri terbukti |
| Kendali server lewat SSM | SSH | tanpa mengelola kunci; Security Group tertutup dari internet |
| ALB di depan gateway | langsung ke server | satu alamat, health check, tiga zona |
| HTTPS lewat CloudFront | HTTPS di ALB | ACM dan Route 53 tidak ada |
| CloudFront dua jalur (S3 + ALB + Lambda) | CloudFront → ALB saja | halaman di-cache edge, server hanya mengurus API |
| Override untuk memori, `stack.yaml` untuk perbaikan bug | semuanya di override | `stack deploy -c a -c b` menambahkan daftar healthcheck, tidak menggantinya |
| 9, bukan 10 atau lebih | meluncurkan lebih banyak | kelebihan dihentikan sistem lab dalam ± 10 detik (bagian 2) |

---

## 9. Daftar bukti

| Pernyataan | Bukti |
|---|---|
| API menerima instance ke-10 sampai ke-38, tetapi kelebihan dihentikan sistem lab; batas berlaku lintas region | [`uji-instance-ke-10.log`](bukti-aws/log-cloudshell/uji-instance-ke-10.log), [`uji-batas-instance.log`](bukti-aws/log-cloudshell/uji-batas-instance.log), [`uji-batas-pelaku.log`](bukti-aws/log-cloudshell/uji-batas-pelaku.log), [`uji-batas-region.log`](bukti-aws/log-cloudshell/uji-batas-region.log), gambar [`26`](bukti-aws/26-percobaan-instance-ke-10-berhasil-dibuat.jpg) dan [`27`](bukti-aws/27-uji-batas-region-dihentikan-9-detik.jpg) |
| `t3.medium` dan `t3.large` ditolak; `t2.small` dan `t3.small` diizinkan | [`uji-tipe-instance.log`](bukti-aws/log-cloudshell/uji-tipe-instance.log), [`analisis-batas.log`](bukti-aws/log-cloudshell/analisis-batas.log) |
| Penempatan layanan | [`penempatan-layanan.txt`](bukti-aws/log-cloudshell/penempatan-layanan.txt) |
| Memori dan hitungan akhir | [`21-memori-9-server-38-layanan.jpg`](bukti-aws/21-memori-9-server-38-layanan.jpg), [`25-semua-layanan-penuh-38-ditambah-registry.jpg`](bukti-aws/25-semua-layanan-penuh-38-ditambah-registry.jpg) |
| Uji matikan s4 | [`08` sampai `12`](bukti-aws/) dan `log-cloudshell/mon.log`, `saat-mati.txt` |
| Aturan Readme (9 instance, 32 vCPU) | **belum dilampirkan**; Ridlo dapat menambahkan tangkapan layar tombol Readme di halaman lab |
