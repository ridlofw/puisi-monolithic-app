<?php
declare(strict_types=1);

namespace Puisi;

use PDO;

final class PuisiRepo
{
    public static function uuidV4(): string
    {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
        $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($bytes), 4));
    }

    /**
     * Format baris database menjadi struktur respons JSON sesuai kontrak/README.md.
     *
     * @param array<string, mixed> $baris
     * @return array<string, mixed>
     */
    public static function formatBaris(array $baris): array
    {
        $analisis = [];
        if (isset($baris['analisis']) && is_string($baris['analisis']) && $baris['analisis'] !== '') {
            $decoded = json_decode($baris['analisis'], true);
            if (is_array($decoded)) {
                $analisis = $decoded;
            }
        } elseif (isset($baris['analisis']) && is_array($baris['analisis'])) {
            $analisis = $baris['analisis'];
        }

        return [
            'id'              => (int) $baris['id'],
            'judul'           => (string) $baris['judul'],
            'isi'             => (string) $baris['isi'],
            'penulis'         => (string) $baris['penulis'],
            'tgl_submit'      => (string) $baris['tgl_submit'],
            'kategori'        => $baris['kategori'] !== null ? (string) $baris['kategori'] : null,
            'keyword'         => $baris['keyword'] !== null ? (string) $baris['keyword'] : null,
            'file_gambar'     => $baris['file_gambar'] !== null ? (string) $baris['file_gambar'] : null,
            'status_analisis' => (string) ($baris['status_analisis'] ?? 'diproses'),
            'status_audio'    => (string) ($baris['status_audio'] ?? 'diproses'),
            'analisis'        => (object) $analisis,
            'url_audio'       => $baris['url_audio'] !== null ? (string) $baris['url_audio'] : null,
        ];
    }

    /**
     * Cari kiriman sebelumnya dengan kunci idempotensi yang sama. Dibaca dari primary agar
     * tidak tertinggal replikasi.
     *
     * @return ?int puisi_id kiriman sebelumnya, null bila kunci belum pernah dipakai
     * @throws KonflikIdempotensi bila kunci sama dipakai untuk isi berbeda
     */
    public static function cariKirimanSebelumnya(PDO $pdo, string $userId, string $kunci, string $sidik): ?int
    {
        $stmt = $pdo->prepare('SELECT puisi_id, sidik FROM idempotensi WHERE user_id = :u AND kunci = :k');
        $stmt->execute([':u' => $userId, ':k' => $kunci]);
        $baris = $stmt->fetch();
        if (!is_array($baris)) {
            return null;
        }
        if (!hash_equals((string) $baris['sidik'], $sidik)) {
            throw new KonflikIdempotensi('Idempotency-Key ini sudah dipakai untuk puisi dengan isi berbeda.');
        }
        return (int) $baris['puisi_id'];
    }

    /**
     * INSERT puisi, INSERT outbox, dan bila ada INSERT idempotensi dalam satu transaksi atomik.
     * Kiriman ulang dengan kunci yang sama mengembalikan puisi yang sudah ada tanpa event baru.
     *
     * @param array{sub: string, username: string, nama: string} $klaim
     * @param array{judul: string, isi: string, tgl_submit: string, kategori: ?string, keyword: ?string, file_gambar: ?string} $input
     * @return array{id: int, ulang: bool}
     */
    public static function simpanDenganOutbox(array $klaim, array $input, string $correlationId, ?string $kunci = null): array
    {
        $correlationId = trim($correlationId) !== '' ? trim($correlationId) : self::uuidV4();
        $sidik         = Validasi::sidik($input);

        for ($percobaan = 1; $percobaan <= 2; $percobaan++) {
            try {
                $pdo = Db::tulis();
                if ($kunci !== null) {
                    $sebelumnya = self::cariKirimanSebelumnya($pdo, (string) $klaim['sub'], $kunci, $sidik);
                    if ($sebelumnya !== null) {
                        return ['id' => $sebelumnya, 'ulang' => true];
                    }
                }
                $pdo->beginTransaction();

                $stmtPuisi = $pdo->prepare(
                    'INSERT INTO puisi
                        (user_id, penulis, judul, isi, tgl_submit, kategori, keyword, file_gambar, status_analisis, status_audio, analisis, url_audio)
                     VALUES
                        (:user_id, :penulis, :judul, :isi, :tgl_submit, :kategori, :keyword, :file_gambar, :status_analisis, :status_audio, :analisis, NULL)'
                );
                $stmtPuisi->execute([
                    ':user_id'         => $klaim['sub'],
                    ':penulis'         => $klaim['nama'],
                    ':judul'           => $input['judul'],
                    ':isi'             => $input['isi'],
                    ':tgl_submit'      => $input['tgl_submit'],
                    ':kategori'        => $input['kategori'],
                    ':keyword'         => $input['keyword'],
                    ':file_gambar'     => $input['file_gambar'],
                    ':status_analisis' => 'diproses',
                    ':status_audio'    => 'diproses',
                    ':analisis'        => '{}',
                ]);

                $puisiId = (int) $pdo->lastInsertId();
                $eventId = self::uuidV4();
                $waktu   = (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))->format('Y-m-d\TH:i:sP');

                $amplop = [
                    'event_id'       => $eventId,
                    'tipe'           => 'puisi.dibuat',
                    'versi'          => 1,
                    'terjadi_pada'   => $waktu,
                    'correlation_id' => $correlationId,
                    'data'           => [
                        'puisi_id' => $puisiId,
                        'judul'    => $input['judul'],
                        'isi'      => $input['isi'],
                        'penulis'  => $klaim['nama'],
                        'kategori' => $input['kategori'],
                        'keyword'  => $input['keyword'],
                    ],
                ];

                $stmtOutbox = $pdo->prepare(
                    'INSERT INTO outbox (event_id, routing_key, payload)
                     VALUES (:event_id, :routing_key, :payload)'
                );
                $stmtOutbox->execute([
                    ':event_id'    => $eventId,
                    ':routing_key' => 'puisi.dibuat',
                    ':payload'     => json_encode($amplop, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                ]);

                if ($kunci !== null) {
                    // kiriman kembar yang bersamaan berebut primary key yang sama; yang kalah mendapat 23000
                    $pdo->prepare(
                        'INSERT INTO idempotensi (user_id, kunci, sidik, puisi_id)
                         VALUES (:user_id, :kunci, :sidik, :puisi_id)'
                    )->execute([
                        ':user_id'  => $klaim['sub'],
                        ':kunci'    => $kunci,
                        ':sidik'    => $sidik,
                        ':puisi_id' => $puisiId,
                    ]);
                }

                $pdo->commit();
                return ['id' => $puisiId, 'ulang' => false];
            } catch (KonflikIdempotensi $e) {
                throw $e;
            } catch (\Throwable $e) {
                if (isset($pdo) && $pdo instanceof PDO && $pdo->inTransaction()) {
                    try {
                        $pdo->rollBack();
                    } catch (\Throwable) {
                    }
                }
                if ($kunci !== null && $e instanceof \PDOException && $e->getCode() === '23000') {
                    $sebelumnya = self::cariKirimanSebelumnya($pdo, (string) $klaim['sub'], $kunci, $sidik);
                    if ($sebelumnya !== null) {
                        return ['id' => $sebelumnya, 'ulang' => true];
                    }
                }
                if (Skema::tabelHilang($e) && $percobaan === 1) {
                    Skema::pastikan(Db::tulis());
                    continue;
                }
                Db::putus();
                if ($percobaan === 2) {
                    throw $e;
                }
            }
        }

        throw new \RuntimeException('Gagal menyimpan puisi.');
    }

    /**
     * Ambil daftar puisi untuk galeri (terurut terbaru).
     *
     * @return list<array<string, mixed>>
     */
    public static function daftar(int $hal = 1, int $perHal = 12): array
    {
        $hal    = max(1, $hal);
        $perHal = max(1, min(50, $perHal));
        $offset = ($hal - 1) * $perHal;

        for ($percobaan = 1; $percobaan <= 2; $percobaan++) {
            try {
                $pdo  = Db::baca();
                $stmt = $pdo->prepare(
                    'SELECT id, user_id, penulis, judul, isi, tgl_submit, kategori, keyword,
                            file_gambar, status_analisis, status_audio, analisis, url_audio
                     FROM puisi
                     ORDER BY id DESC
                     LIMIT :batas OFFSET :offset'
                );
                $stmt->bindValue(':batas', $perHal, PDO::PARAM_INT);
                $stmt->bindValue(':offset', $offset, PDO::PARAM_INT);
                $stmt->execute();

                $hasil = [];
                foreach ($stmt->fetchAll() as $baris) {
                    $hasil[] = self::formatBaris($baris);
                }
                return $hasil;
            } catch (\Throwable $e) {
                Db::putus();
                if ($percobaan === 2) {
                    throw $e;
                }
            }
        }

        return [];
    }

    /**
     * Ambil detail satu puisi. Bila tidak ditemukan di replika baca, otomatis cek Primary
     * sekali agar puisi yang baru saja dikirim tidak terkena replication lag.
     *
     * @return ?array<string, mixed>
     */
    public static function detail(int $id, bool $paksaPrimary = false): ?array
    {
        $sql = 'SELECT id, user_id, penulis, judul, isi, tgl_submit, kategori, keyword,
                       file_gambar, status_analisis, status_audio, analisis, url_audio
                FROM puisi WHERE id = :id LIMIT 1';

        if (!$paksaPrimary) {
            try {
                $stmt = Db::baca()->prepare($sql);
                $stmt->bindValue(':id', $id, PDO::PARAM_INT);
                $stmt->execute();
                $baris = $stmt->fetch();
                if (is_array($baris)) {
                    return self::formatBaris($baris);
                }
            } catch (\Throwable) {
                Db::putus();
            }
        }

        $stmt = Db::tulis()->prepare($sql);
        $stmt->bindValue(':id', $id, PDO::PARAM_INT);
        $stmt->execute();
        $baris = $stmt->fetch();
        return is_array($baris) ? self::formatBaris($baris) : null;
    }

    public static function hitungOutboxTertunda(): int
    {
        try {
            $baris = Db::baca()->query('SELECT COUNT(*) AS jml FROM outbox WHERE terkirim_pada IS NULL')->fetch();
            return is_array($baris) ? (int) ($baris['jml'] ?? 0) : 0;
        } catch (\Throwable) {
            return 0;
        }
    }

    /**
     * Terapkan event hasil (puisi.dianalisis atau audio.siap) ke baris puisi secara atomik & idempoten.
     * Mengembalikan false bila puisi_id tidak ditemukan di basis data.
     *
     * @param array<string, mixed> $amplop
     */
    public static function terapkanHasilEvent(array $amplop): bool
    {
        $puisiId = (int) ($amplop['data']['puisi_id'] ?? 0);
        if ($puisiId <= 0) {
            throw new \InvalidArgumentException('puisi_id tidak sah.');
        }

        for ($percobaan = 1; $percobaan <= 2; $percobaan++) {
            try {
                $pdo = Db::tulis();
                $pdo->beginTransaction();

                $stmtPilih = $pdo->prepare(
                    'SELECT id, kategori, keyword, file_gambar, status_analisis, status_audio, analisis, url_audio
                     FROM puisi
                     WHERE id = :id
                     FOR UPDATE'
                );
                $stmtPilih->execute([':id' => $puisiId]);
                $lama = $stmtPilih->fetch();

                if (!is_array($lama)) {
                    $pdo->rollBack();
                    return false;
                }

                $baru = GabungHasil::terapkan($lama, $amplop, Konfig::sumberWajib());

                $stmtUpdate = $pdo->prepare(
                    'UPDATE puisi
                     SET kategori        = :kategori,
                         keyword         = :keyword,
                         file_gambar     = :file_gambar,
                         status_analisis = :status_analisis,
                         status_audio    = :status_audio,
                         analisis        = :analisis,
                         url_audio       = :url_audio
                     WHERE id = :id'
                );
                $stmtUpdate->execute([
                    ':kategori'        => $baru['kategori'],
                    ':keyword'         => $baru['keyword'],
                    ':file_gambar'     => $baru['file_gambar'],
                    ':status_analisis' => $baru['status_analisis'],
                    ':status_audio'    => $baru['status_audio'],
                    ':analisis'        => json_encode((object) $baru['analisis'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                    ':url_audio'       => $baru['url_audio'],
                    ':id'              => $puisiId,
                ]);

                $pdo->commit();
                return true;
            } catch (\Throwable $e) {
                if (isset($pdo) && $pdo instanceof PDO && $pdo->inTransaction()) {
                    try {
                        $pdo->rollBack();
                    } catch (\Throwable) {
                    }
                }
                Db::putus();
                if ($percobaan === 2) {
                    throw $e;
                }
            }
        }

        return false;
    }
}

