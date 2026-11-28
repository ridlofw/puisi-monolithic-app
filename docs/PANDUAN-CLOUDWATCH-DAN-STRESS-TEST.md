# Panduan CloudWatch dan Cara Membaca Stress Test

**Untuk siapa:** tim yang akan menjalankan stress test pada versi Single (1 server) dan Scalable (9 server) lalu membandingkannya.
Dokumen ini hanya menjelaskan **cara melihat dan membaca** angka. Stress test-nya sendiri belum dijalankan di AWS, dan tempat menjalankan
alat beban (laptop atau AWS) belum diputuskan tim.

Label kejujuran: **[terbukti]** = sudah saya jalankan di sandbox 28 Nov 2026; **[dari dokumen AWS]** = pengetahuan umum tentang AWS yang belum
saya uji di sandbox ini; **[contoh]** = angka contoh dari uji lain, bukan hasil AWS.

---

## 0. Sebelum merancang: batas yang ada di jalur permintaan (dicek 28 Nov 2026)

Pertanyaan tim: "apakah AWS membatasi per IP?". Jawabannya, dicek pada sistem 9 server yang berjalan **[terbukti, hanya membaca]**
(keluaran: [`bukti-aws/log-cloudshell/deploy-9server-sentinel-28nov.txt`](bukti-aws/log-cloudshell/deploy-9server-sentinel-28nov.txt)):

| Bagian | Batas | Siapa yang memasang |
|---|---|---|
| CloudFront dan ALB | **tidak ada batas per IP**: tidak ada WAF (`WAF CloudFront: 0`, `WAF regional: 0`, distribusi tanpa WebACL). Keduanya menskalakan diri sendiri | AWS (tanpa pengaturan dari kita) |
| CPU 9 server | kredit CPU `unlimited` di kesembilannya: CPU **tidak diperlambat** saat kredit habis, tetapi pemakaian di atas 20% lama-lama ditagih sedikit | AWS (bawaan `t3`) |
| Lambda (gambar kutipan) | 1000 eksekusi bersamaan | AWS |
| **Gateway (nginx), per IP pengunjung dan per gateway** | login 10 per menit (burst 5); kirim puisi 5 per detik (burst 30); pencarian 30 per detik (burst 60). Lebih dari itu dijawab `429` | **kode kita** (Bab 10 Pison, `gateway/nginx.conf`, `gateway/rute/*.conf`) |
| **Gateway, cache** | `GET /api/puisi` dan pencarian yang sama disimpan **10 detik** di gateway | **kode kita** |

Akibatnya bagi stress test:
- Dari **satu IP**, angka maksimal kirim puisi dan pencarian yang terlihat adalah **batas 429 gateway kita**, bukan kemampuan server. Scalable punya 3 gateway (sekitar 3 kali lipat), Single 1.
  Untuk mencari kemampuan server sungguhan, tim harus memilih: (a) menguji jalur baca saja, (b) memakai banyak sumber IP, atau (c) memakai image gateway khusus uji dengan batas dilonggarkan
  (dicatat jelas di laporan). Belum diputuskan.
- Permintaan baca yang sama dijawab dari cache gateway, jadi yang terukur adalah nginx. `scripts/uji_stres.py` sudah mengacak kata pencarian supaya sebagian melewati cache.
- **Alat beban sendiri bisa menjadi leher botol.** CloudShell hanya 2 vCPU dan 3,8 GB RAM. Bila CPU alat beban mendekati 100%, angka tahap itu tidak sah.

Pilihan tempat alat beban (belum diputuskan tim):

| Pilihan | Kelebihan | Kekurangan |
|---|---|---|
| Laptop | gratis, mudah | jaraknya jauh dari us-east-1 (setiap permintaan menempuh internet ke Amerika), kecepatan internet laptop ikut terukur |
| CloudShell | satu region dengan server, tidak memakai slot instance | 2 vCPU; satu IP; sesi bisa berhenti bila diam |
| **EC2 di akun teman** (disarankan) | satu region, latensi rendah; bisa beberapa server = beberapa IP; tidak memakai slot 9 server milik akun yang diuji | butuh akun kedua; Single di akun teman harus dimatikan saat menguji Scalable, atau sebaliknya alat beban dipasang di akun yang tidak sedang dipakai |
| Lambda sebagai alat beban | banyak eksekusi dan IP | perlu dibuat dan diuji dulu |

Instance AWS dipakai bukan karena "internetnya kencang" saja, melainkan karena letaknya dekat dengan server (jeda jaringan kecil dan stabil), jadi yang terukur benar-benar
kemampuan aplikasi, bukan internet di antaranya. Satu hal yang **belum saya cek**: aturan pemakaian AWS Academy dan kebijakan AWS untuk uji beban
bervolume sangat besar (yang menyerupai serangan). Uji beban terhadap aplikasi sendiri dengan volume wajar umumnya diperbolehkan; periksa halaman aturan lab sebelum menjalankan uji besar.

---

## 1. CloudWatch itu apa?

Analogi: CloudWatch adalah **dasbor mobil** untuk server EC2. Tanpa memasang apa pun, AWS sudah mencatat beberapa "jarum" setiap server:
seberapa sibuk mesinnya (CPU), berapa banyak data keluar-masuk jaringan, berapa banyak baca-tulis disk. **[terbukti]**

Yang **tidak** ada di dasbor bawaan: **memori (RAM)** dan angka per container. Untuk itu ada `bash ~/1server.sh memori` (Single) atau
`bash ~/9server.sh memori` (Scalable). **[terbukti]** (Memori bisa masuk CloudWatch lewat CloudWatch Agent, tetapi itu belum diuji di sandbox.)

Metrik bawaan dicatat **per 5 menit** (basic monitoring). **[terbukti: titik datanya berjarak 5 menit]** Angka yang tampil adalah
**rata-rata** 5 menit itu (bisa juga dilihat maksimumnya). Data baru biasanya muncul beberapa menit sesudah kejadian.

---

## 2. Cara membuka CloudWatch

### Cara 1: lewat Console (klik)

1. Console AWS -> **EC2** -> **Instances** -> centang server (`puisi-single`, atau `puisi-s1` .. `puisi-s9`).
2. Di bagian bawah pilih tab **Monitoring**. Muncul grafik CPU utilization, Network in/out, EBS read/write, Status check, dan CPU credit.
3. Di pojok kanan atas grafik, atur rentang waktu (misalnya **1h**) dan klik ikon muat ulang.
4. Untuk grafik lebih lengkap: klik satu grafik -> **View in metrics** (membuka CloudWatch). Di sana bisa memilih statistik
   **Average** atau **Maximum**, dan menggabungkan beberapa server dalam satu grafik (berguna untuk Scalable).

Ingat: bilah atas console memuat nomor akun. Potong sebelum membagikan tangkapan layar.

### Cara 2: lewat CloudShell (perintah) [terbukti]

CPU rata-rata dan maksimum per 5 menit selama 40 menit terakhir untuk server Single:

```bash
ID=$(cat ~/puisi1/instance-id)
aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=$ID --start-time $(date -u -d '-40 min' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Average Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' --output text
```

Ganti `CPUUtilization` dengan nama metrik lain dari tabel di bagian 3. Untuk Scalable, ambil ID server dari `~/puisi9/servers.tsv`.

Contoh hasil asli server Single, 28 Nov 2026 **[terbukti]**:

```
10:28  rata-rata 26,9 %  maks  97,2 %   server baru menyala, memasang Docker
10:33  rata-rata 64,9 %  maks 100,0 %   membangun 8 image
10:38  rata-rata 29,3 %  maks  58,8 %   menyalakan 18 container
10:43  rata-rata 21,0 %  maks  24,4 %   aplikasi berjalan, uji e2e
10:48  rata-rata 20,7 %  maks  22,6 %   aplikasi berjalan tanpa pengguna
```

Cara membacanya: saat **tanpa pengguna**, server Single sudah sibuk sekitar 21%. Itu "biaya diam" 18 container di satu mesin kecil.

---

## 3. Metrik yang penting dan artinya

| Metrik | Artinya (bahasa sederhana) | Kapan perlu khawatir |
|---|---|---|
| `CPUUtilization` | Persen waktu prosesor sibuk (2 vCPU dihitung bersama) | Mendekati 100% terus-menerus: prosesor sudah mentok |
| `CPUCreditBalance` | Tabungan "kredit CPU". `t3.small` hanya dijamin 20% CPU; di atas itu memakai tabungan | Turun terus selama uji |
| `CPUSurplusCreditsCharged` | Kredit yang dipakai melebihi tabungan dan **ditagih** (mode `unlimited`) | Naik: uji berjalan di atas 20% cukup lama (biaya kecil, CPU tidak diperlambat) |
| `NetworkIn`, `NetworkOut` | Byte masuk dan keluar selama satu periode | Bandingkan dengan jumlah request; bagi 300 untuk byte per detik |
| `EBSReadBytes`, `EBSWriteBytes`, `EBSReadOps`, `EBSWriteOps` | Baca-tulis disk. **Di Single, swap ada di disk**, jadi swap ikut terlihat di sini | `EBSReadBytes` melonjak saat uji: data diambil kembali dari swap (lambat) |
| `StatusCheckFailed` | 1 berarti server atau perangkat kerasnya bermasalah | Apa pun selain 0 |

Mode kredit server kita `unlimited` **[terbukti: `luncurkan` mencetak `kredit CPU: unlimited`]**: CPU **tidak** diperlambat ketika tabungan habis,
tetapi kelebihannya ditagih. (Dalam mode `standard`, CPU akan dipaksa turun ke 20% saat tabungan habis; kurva stress test lalu patah tiba-tiba.
**[dari dokumen AWS]**)

---

## 4. Membaca stress test

### 4.1 Dua sumber angka, dua peran

| Sumber | Menjawab | Contoh angka |
|---|---|---|
| **Alat beban** (`scripts/uji_stres.py`) | **Apa yang dirasakan pengguna**: berapa request per detik terlayani, berapa lama, berapa yang gagal | rps, P50, P95, P99, galat, 429 |
| **Server** (CloudWatch, `memori`) | **Kenapa** angkanya begitu: bagian mana yang penuh | CPU %, swap, memori per container |

Keputusan "titik maksimal" diambil dari **alat beban**. Angka server dipakai untuk menjelaskan penyebabnya.

Istilah di keluaran `uji_stres.py`:

- **Pengguna**: jumlah pengguna virtual yang mengirim request terus-menerus tanpa jeda.
- **rps**: request per second, berapa request yang selesai per detik. Inilah **kapasitas** (throughput).
- **P50 / P95 / P99**: waktu tunggu. P99 = 500 ms berarti 99 dari 100 request selesai dalam 500 ms, dan 1 sisanya lebih lambat.
  P99 dipakai karena rata-rata menyembunyikan pengguna yang paling menderita.
- **Galat**: persen request yang gagal (5xx atau putus).
- **429**: request yang sengaja ditolak gateway karena batas per IP. **Bukan galat**, tetapi berarti alat beban dari satu IP ikut dibatasi.
- **SLO**: target kita (`docs/SLO.md`): **P99 di bawah 500 ms dan galat di bawah 1%**. Kolom ini menulis `ok` atau `melanggar`.

### 4.2 Tiga titik yang dicari

Analogi: jalan tol. Menambah mobil awalnya menambah jumlah mobil yang lewat per menit. Suatu saat jalan penuh: mobil yang lewat per menit
**tidak bertambah lagi**, hanya antrean yang makin panjang. Kalau terus ditambah, ada mobil yang mogok.

| Titik | Tanda di tabel `uji_stres.py` | Arti |
|---|---|---|
| **Titik jenuh** ("mentok") | `rps` **berhenti naik** walaupun pengguna ditambah; P50 dan P99 mulai naik lurus | Kapasitas maksimum sistem sudah tercapai. Angka rps di sini adalah **kapasitas maksimal** |
| **Titik hancur SLO** | Tahap pertama yang kolom SLO-nya `melanggar` (P99 > 500 ms atau galat > 1%) | Jumlah pengguna maksimum yang masih memenuhi target. **Ini angka utama untuk presentasi** |
| **Titik rusak** | Galat mulai muncul (5xx, putus), container restart, atau server tidak menjawab | Sistem bukan lagi lambat, tetapi gagal |

Cara menentukannya: susun tabel per tahap (1, 5, 10, 20, 40, 80, 160, 320 pengguna), lalu:

1. Cari tahap ketika `rps` tidak naik lebih dari sekitar 10% dibanding tahap sebelumnya: itu **titik jenuh**.
2. Cari tahap pertama `melanggar`: **titik hancur SLO** ada di antara tahap itu dan tahap sebelumnya. Bila perlu angka lebih tepat,
   ulangi dengan tahap di antaranya (misalnya `--tahap 160,200,240,280`).
3. Cari tahap pertama dengan galat lebih dari 0: **titik rusak**.

**[contoh]** Hasil laptop 23 Nov 2026 di `docs/SLO.md` (bukan AWS):

| Pengguna | rps | P99 ms | SLO |
|---|---|---|---|
| 5 | 687 | 27 | ok |
| 10 | 846 | 33 | ok |
| 20 | 843 | 60 | ok |
| 40 | 907 | 83 | ok |
| 160 | 875 | 250 | ok |
| 320 | 812 | 557 | melanggar |

Dibaca: dari 10 pengguna ke atas rps tetap di sekitar 850 sampai 900 (**titik jenuh sekitar 10 pengguna, kapasitas sekitar 850 rps**),
sementara P99 terus naik. **Titik hancur SLO di antara 160 dan 320 pengguna.** Galat 0% di semua tahap: belum ada titik rusak (sistem melambat,
bukan rusak).

### 4.3 Mencari penyebab (bottleneck) dengan angka server

Jalankan `bash ~/1server.sh memori` (atau `9server.sh memori`) **saat** sebuah tahap sedang berjalan, lalu cocokkan:

| Yang terlihat | Kesimpulan |
|---|---|
| CPU server mendekati 100% (CloudWatch Maximum, atau CPU % per container di `memori`) | Prosesor mentok. Container dengan CPU % terbesar adalah tersangkanya (di laptop: OpenSearch) |
| `vmstat si` besar (ribuan KB/detik) dan `EBSReadBytes` naik | Memori kurang, data diambil dari swap. Ini yang paling mungkin terjadi pada **Single** |
| CPU dan memori longgar, tetapi P99 tetap naik | Antrean di tempat lain: batas 429 per IP, koneksi database (`max_connections=100`), atau mesin alat beban yang mentok |
| Galat 5xx muncul bersamaan dengan container `Restarting` | Ada container yang mati (sering karena kehabisan memori) |

### 4.4 Supaya perbandingan Single dan Scalable adil

- Pakai **alat, tahap, durasi, dan lokasi alat beban yang sama** untuk keduanya.
- Lama tiap tahap minimal 5 menit bila ingin CloudWatch ikut dipakai (periode 5 menit). Untuk tahap pendek, andalkan `memori` saat tahap berjalan.
- Alat beban dari **satu IP** akan terkena batas 429 gateway (30 pencarian per detik, 5 kirim puisi per detik per IP). Laporkan kolom 429.
- Catat keadaan awal: Single sudah memakai swap sekitar 1,7 GB dan CPU sekitar 21% **sebelum** diberi beban **[terbukti]**.
- Pada Scalable, lihat **server yang paling sibuk**, bukan rata-rata 9 server.
- Simpan keluaran mentah (`--json hasil.json`) dan potongan CloudWatch sebagai bukti.

---

## 5. Ringkas: yang dikatakan saat presentasi

1. "Kapasitas maksimal Single adalah **X rps** (titik jenuh), dan Scalable **Y rps**."
2. "Single memenuhi SLO sampai **A pengguna**, Scalable sampai **B pengguna** (titik hancur SLO)."
3. "Penyebab Single mentok adalah **...** (CPU, swap, atau komponen tertentu), terlihat dari CloudWatch dan `memori`."
4. "Pada Scalable, satu server dimatikan dan sistem tetap jalan; pada Single, satu server mati berarti semuanya mati."

Angka X, Y, A, B baru ada setelah stress test benar-benar dijalankan.
