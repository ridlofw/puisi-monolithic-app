<?php
declare(strict_types=1);

namespace Puisi;

final class Validasi
{
    /**
     * Validasi input POST /api/puisi sesuai kontrak/README.md dan Tugas-Ridlo.md R1:
     * - judul dan isi wajib diisi
     * - kategori dan keyword boleh kosong (menjadi null agar diisi Auto-tagging)
     * - file_gambar opsional, tetapi bila diisi wajib sesuai pola puisi_<angka>.jpeg
     *
     * @param array<string, mixed> $input
     * @return array{judul: string, isi: string, tgl_submit: string, kategori: ?string, keyword: ?string, file_gambar: ?string}
     */
    public static function puisiBaru(array $input): array
    {
        $judul      = is_string($input['judul'] ?? null) ? trim($input['judul']) : '';
        $isi        = is_string($input['isi'] ?? null) ? trim($input['isi']) : '';
        $tglSubmit  = is_string($input['tgl_submit'] ?? null) ? trim($input['tgl_submit']) : '';
        $kategori   = isset($input['kategori']) && is_string($input['kategori']) ? trim($input['kategori']) : '';
        $keyword    = isset($input['keyword']) && is_string($input['keyword']) ? trim($input['keyword']) : '';
        $fileGambar = isset($input['file_gambar']) && is_string($input['file_gambar']) ? trim($input['file_gambar']) : '';

        if ($judul === '' || $isi === '') {
            throw new \InvalidArgumentException('Field judul dan isi puisi wajib diisi.');
        }

        if (mb_strlen($judul) > 200) {
            throw new \InvalidArgumentException('Judul puisi maksimal 200 karakter.');
        }

        if ($tglSubmit === '') {
            $tglSubmit = date('Y-m-d');
        } elseif (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $tglSubmit)) {
            throw new \InvalidArgumentException('Format tgl_submit harus YYYY-MM-DD.');
        }

        if ($fileGambar !== '' && !preg_match('/^puisi_\d{1,16}\.jpeg$/', $fileGambar)) {
            throw new \InvalidArgumentException('File gambar puisi tidak valid.');
        }

        return [
            'judul'       => $judul,
            'isi'         => $isi,
            'tgl_submit'  => $tglSubmit,
            'kategori'    => $kategori !== '' ? $kategori : null,
            'keyword'     => $keyword !== '' ? $keyword : null,
            'file_gambar' => $fileGambar !== '' ? $fileGambar : null,
        ];
    }

    /**
     * Header Idempotency-Key bersifat opsional. Bila dikirim, wajib 8 sampai 64 karakter
     * huruf, angka, garis bawah, atau tanda hubung (UUID memenuhi aturan ini).
     */
    public static function kunciIdempotensi(?string $nilai): ?string
    {
        if ($nilai === null || trim($nilai) === '') {
            return null;
        }
        $nilai = trim($nilai);
        if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $nilai)) {
            throw new \InvalidArgumentException('Header Idempotency-Key harus 8 sampai 64 karakter huruf, angka, _ atau -.');
        }
        return $nilai;
    }

    /**
     * Sidik isi puisi yang sudah divalidasi, untuk membedakan kirim ulang yang sama
     * dari pemakaian ulang kunci dengan isi berbeda.
     *
     * @param array{judul: string, isi: string, tgl_submit: string, kategori: ?string, keyword: ?string, file_gambar: ?string} $input
     */
    public static function sidik(array $input): string
    {
        $urut = [];
        foreach (['judul', 'isi', 'tgl_submit', 'kategori', 'keyword', 'file_gambar'] as $k) {
            $urut[$k] = $input[$k] ?? null;
        }
        return hash('sha256', json_encode($urut, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }
}

