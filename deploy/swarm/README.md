# deploy/swarm: menjalankan aplikasi puisi di banyak server (Docker Swarm)

**Tujuan:** menjalankan aplikasi di **banyak server AWS di zona berbeda, satu kelompok server untuk setiap
microservice**, supaya matinya satu server tidak menghentikan aplikasi, dan supaya kapasitas tiap microservice
bisa **ditambah dengan menambah servernya sendiri**.

> ## Mulai dari sini bila Anda pemula
> Baca **berurutan** folder [`panduan/`](panduan/). Ditulis untuk orang yang belum pernah memegang
> microservice, Docker, atau AWS.
>
> | Urutan | Dokumen | Menjawab pertanyaan |
> |---|---|---|
> | 1 | [`panduan/1-konsep-dasar.md`](panduan/1-konsep-dasar.md) | Apa itu microservice, container, Swarm, server, zona, Security Group, load balancer? |
> | 2 | [`panduan/2-antar-microservice.md`](panduan/2-antar-microservice.md) | **Bagaimana layanan saling terhubung?** Dan bagaimana memeriksanya? |
> | 3 | [`../../docs/PANDUAN-DEPLOY-AWS.md`](../../docs/PANDUAN-DEPLOY-AWS.md) | **Langkah praktik dari nol sampai aplikasi berjalan** (satu-satunya panduan deploy) |
> | 4 | [`../../docs/ARSITEKTUR-DEPLOY-AWS.md`](../../docs/ARSITEKTUR-DEPLOY-AWS.md) | **Arsitektur yang berjalan**: kenapa 9 server, penempatan layanan, hubungan antar-server |
> | 5 | [`../../docs/LAPORAN-EKSPERIMEN-AWS.md`](../../docs/LAPORAN-EKSPERIMEN-AWS.md) | Apa yang terukur di AWS, temuan, bukti, skenario uji mematikan server |
> | 6 | [`../lambda/README.md`](../lambda/README.md) | Gambar kutipan dengan AWS Lambda (Hands-on 1) |

> **Status jujur (23 November 2026):** `stack.yaml` **dijalankan di AWS sandbox**: 9 server `t3.small` di 3 zona, 38 layanan penuh, `uji_e2e.py` 10 dari 10, dan satu server
> pemegang PRIMARY database dimatikan tanpa probe gagal (saat itu 23 layanan). Rancangan **satu pool per microservice** berjalan sebagai label: di 9 server, tiap server membawa beberapa label pool.
> Satu perbaikan lahir dari uji itu (healthcheck OpenSearch di `stack.yaml`). Komponen yang masih tunggal: `seaweedfs` (audio) dan `redis` (cache). Jangan menulis "bebas SPOF".
> Angka, temuan, dan bukti: [`docs/LAPORAN-EKSPERIMEN-AWS.md`](../../docs/LAPORAN-EKSPERIMEN-AWS.md); cara mengulang: [`docs/PANDUAN-DEPLOY-AWS.md`](../../docs/PANDUAN-DEPLOY-AWS.md).

## Rancangan: satu kelompok server (pool) untuk setiap microservice

Setiap microservice bisa punya **server sendiri**, lengkap dengan datanya. Kegagalan di satu kelompok tidak
menyentuh kelompok lain, dan tiap kelompok bisa ditambah servernya sendiri-sendiri. Kelompok disebut **pool**
dan ditandai dengan **label** pada server.

| Kunci pool | Pemilik | Isi | Server minimal |
|---|---|---|---|
| `infra` | Pison | gateway, **RabbitMQ 3 node**, Redis | **3** |
| `auto-tagging` | Pison | auto-tagging | **2** |
| `puisi` | Ridlo | poem-service, relay, consumer, **poem-db (klaster 3 node)** + 2 router | **3** |
| `genre` | Ridlo | klasifikasi-genre | **2** |
| `auth` | Ifham | auth-service, **auth-db (klaster 3 node)** + router | **3** |
| `tts` | Ifham | text-to-speech, **tts-db (klaster 3 node)** + router, SeaweedFS | **3** |
| `pencarian` | Evan | search-service, search-consumer, **OpenSearch 3 node**, HAProxy | **3** |
| `emosi` | Ray | analisis-emosi | **2** |
| | | **Total bila dipisah penuh** | **21 server** |

**Singkatan pemilik** (dipakai `skrip/beri-label.sh`): `pison` = infra + auto-tagging, `ridlo` = puisi + genre,
`ifham` = auth + tts, `evan` = pencarian, `ray` = emosi. Dengan singkatan, microservice milik satu orang berbagi
server: **14 server minimal** (pison 3, ridlo 3, ifham 3, evan 3, ray 2). Dengan kunci, semuanya terpisah.

**Cara kerjanya:**
- Layanan **tanpa data** berjalan `mode: global` di pool pemiliknya: **satu salinan per server**. Menambah
  server ke pool `puisi` (join Swarm + label `puisi.pool.puisi=true`) menambah satu poem-service, relay, dan
  consumer **otomatis**, tanpa mengubah berkas apa pun. Begitu pula pool lain.
- Layanan **berdata** (klaster database, RabbitMQ, OpenSearch) dipaku ke pool + `slot` 1, 2, 3. Setiap
  klaster memakai suara mayoritas, jadi 3 anggota menahan **satu** kegagalan. Itu sebabnya slot hanya 1 sampai 3.
  Server tambahan di sebuah pool **tidak** memegang data, hanya menambah salinan layanan.
- Sebuah server boleh dimiliki **beberapa pool sekaligus** (beberapa label). Berkas stack tidak berubah.

**Susunan server, dari paling terpisah ke paling hemat** (pilih sesuai batas sandbox; **belum diverifikasi**, cek
RENCANA bagian 3):

| Server | Susunan | Perintah label (`beri-label.sh <node> ...`) | Akibatnya |
|---|---|---|---|
| **21** | satu pool per microservice | `puisi 1`, `puisi 2`, `puisi 3`, `genre`, `auth 1..3`, `tts 1..3`, `pencarian 1..3`, `infra 1..3`, `auto-tagging`, `emosi`, ... | semua microservice terpisah penuh, termasuk poem dan genre |
| **14** | satu pool per pemilik | `ridlo 1..3`, `ifham 1..3` (slot 2 + `audio`), `evan 1..3`, `pison 1..3`, `ray` x2 | microservice satu pemilik berbagi server. **Susunan yang disarankan** |
| **9** | `puisi` dan `genre` tetap terpisah, sisanya digabung | `puisi 1..3`, `genre` x2, lalu `auth,tts,pencarian,infra 1..3` (3 server) , `auto-tagging,emosi` x2 | microservice Ridlo punya server sendiri; yang lain berbagi |
| **3** | semua pool di tiap server | `infra,auto-tagging,puisi,genre,auth,tts,pencarian,emosi 1` (dan 2, 3) | seluruh aplikasi di 3 server; **mematikan satu server memengaruhi semua microservice** |

Setiap server di baris 9 dan 3 menjumlahkan memori semua pool yang dipegangnya: **ukur ulang**. Semua susunan
bisa ditambah server ekstra per pool (tanpa slot) untuk kapasitas; yang disarankan lebih dulu: pool `puisi`.

**Mengapa tidak ratusan server:** tiap klaster butuh minimal 3 anggota agar satu server boleh mati, jadi
batas bawah per microservice berdata adalah 3. Lebih dari itu hanya menambah salinan layanan tanpa data,
dan jumlahnya dibatasi kuota sandbox, bukan rancangan. **Setiap layanan sudah berupa container sendiri**
(38 layanan); yang berubah di sini adalah **server**-nya dipisah per microservice.

## Isi folder

| Berkas | Fungsi |
|---|---|
| [`panduan/`](panduan/) | **Konsep untuk pemula** (2 dokumen: konsep dasar, dan bagaimana layanan saling terhubung) |
| [`../aws/`](../aws/) | **Skrip deploy yang dipakai di sandbox**: `9server.sh`, `alb.sh`, `cloudfront-dua-jalur.sh`, `bangun*.sh`, `override-9server.yaml` (lihat `docs/PANDUAN-DEPLOY-AWS.md` bagian 12) |
| [`stack.yaml`](stack.yaml) | Berkas stack Swarm: 38 layanan, penempatan per pool microservice, job init. Setiap sambungan antar-layanan tertulis di sini |
| [`stack.efs.yaml`](stack.efs.yaml) | **Opsional:** data SeaweedFS di Amazon EFS supaya audio tidak terkunci di satu server |
| [`USULAN-PEMILIK.md`](USULAN-PEMILIK.md) | Usulan untuk **teman satu tim** (Pison, Ifham, Evan, Ray): yang sudah ditangani di deploy dan yang masih butuh perubahan kode mereka |
| [`Dockerfile.gateway`](Dockerfile.gateway), [`gateway/00-swarm.conf`](gateway/00-swarm.conf) | Image gateway (halaman web dan konfigurasi dimasukkan ke image), `/healthz`, pembacaan IP klien, dan `CDN_URL` untuk gambar kutipan |
| [`skrip/init-innodb-cluster.sh`](skrip/init-innodb-cluster.sh) | Pembentuk klaster MySQL **umum** (dipakai auth-db dan tts-db; poem-db tetap memakai skrip Ridlo) |
| [`mysql/klaster.cnf`](mysql/klaster.cnf), [`opensearch/haproxy.cfg`](opensearch/haproxy.cfg) | Konfigurasi bersama node MySQL klaster, dan pintu masuk HAProxy ke OpenSearch |
| [`stack.registry.yaml`](stack.registry.yaml) | Cadangan bila ECR tidak ada: registry sendiri di Swarm |
| [`skrip/siapkan-node.sh`](skrip/siapkan-node.sh), [`bangun-image.sh`](skrip/bangun-image.sh), [`cek.sh`](skrip/cek.sh), [`beri-label.sh`](skrip/beri-label.sh), [`user-data.sh`](skrip/user-data.sh) | **Jalur manual (tidak dipakai `9server.sh`)**: pengaturan server, build 8 image, pemeriksaan klaster, pasang label, User data. Berguna bila membuat server tanpa `9server.sh`; **belum diuji di AWS** |
| [`../lambda/`](../lambda/) | Skrip dan panduan AWS Lambda gambar kutipan (Hands-on 1) |

## Ringkasan 30 detik

Langkah lengkap dan terbukti di sandbox: [`docs/PANDUAN-DEPLOY-AWS.md`](../../docs/PANDUAN-DEPLOY-AWS.md) (skrip `deploy/aws/9server.sh`). Garis besarnya:

1. Buat server untuk tiap pool (**9 di sandbox; 14 bila per pemilik, 21 bila dipisah penuh di akun biasa**) di zona berbeda, hubungkan dengan **Docker Swarm**
   (tiga manager, sisanya worker), pasang label pool dan slot.
2. Bangun **image** di server, simpan di registry sendiri (atau ECR di akun biasa).
3. `docker stack deploy -c deploy/swarm/stack.yaml -c deploy/aws/override-9server.yaml puisi` (override hanya untuk server 2 GiB).
4. Pasang **load balancer** di depan server **pool infra** (di sanalah gateway berjalan), dan CloudFront untuk HTTPS.
5. Lambda gambar kutipan: [`../lambda/README.md`](../lambda/README.md).
6. **Matikan satu server** dan catat apa yang tetap hidup.

## Validasi yang bisa diulang di laptop (tanpa mengunduh image)

```powershell
docker stack config -c deploy/swarm/stack.yaml
```

Perintah itu hanya memeriksa sintaks dan variabel. **Jangan** menjalankan `docker swarm init` di Docker
Desktop yang sedang menjalankan stack Compose Anda: itu merusak DNS jaringan Compose (nama layanan tidak lagi terselesaikan; pemulihannya ada di bagian 6 `docs/PANDUAN-PEMULA-RIDLO.md`).
