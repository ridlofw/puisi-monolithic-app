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
}

