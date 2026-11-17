<?php
declare(strict_types=1);

namespace Pencarian;

//Menerjemahkan event menjadi pembaruan dokumen indeks.
//Urutan event tidak dijamin, jadi setiap event hanya menulis kolomnya sendiri dan selalu lewat _update dengan doc_as_upsert
final class Penangan
{
    public const VISIBILITAS = ['publik', 'privat'];
    public const TAG_MAKS    = 20;

    public static function bacaAmplop(string $badan): array
    {
        $a = json_decode($badan, true);
        if (!is_array($a)) {
            throw new \InvalidArgumentException('Pesan bukan JSON objek.');
        }
        foreach (['event_id', 'tipe'] as $k) {
            if (!isset($a[$k]) || !is_string($a[$k]) || $a[$k] === '') {
                throw new \InvalidArgumentException("Amplop tidak punya $k.");
            }
        }
        if (!isset($a['data']) || !is_array($a['data'])) {
            throw new \InvalidArgumentException('Amplop tidak punya data.');
        }
        $id = $a['data']['puisi_id'] ?? null;
        if (!is_int($id) || $id < 1) {
            throw new \InvalidArgumentException('puisi_id harus bilangan bulat positif.');
        }
        $a['correlation_id'] = is_string($a['correlation_id'] ?? null) ? $a['correlation_id'] : '';
        return $a;
    }

    //Dokumen sebagian yang harus digabung ke indeks, atau null bila event tidak mengubah indeks.
    public static function rencana(array $amplop): ?array
    {
        $data = $amplop['data'];
        $id   = $data['puisi_id'];

        $doc = match ($amplop['tipe']) {
            'puisi.dibuat'     => self::dariDibuat($data, $amplop),
            'puisi.dianalisis' => self::dariAnalisis($data),
            default            => [],
        };
        return $doc === [] ? null : ['id' => $id, 'doc' => $doc];
    }

    private static function dariDibuat(array $data, array $amplop): array
    {
        foreach (['judul', 'isi', 'penulis'] as $k) {
            if (!isset($data[$k]) || !is_string($data[$k]) || trim($data[$k]) === '') {
                throw new \InvalidArgumentException("puisi.dibuat tidak punya $k.");
            }
        }
        $doc = [
            'judul'      => trim($data['judul']),
            'isi'        => $data['isi'],
            'penulis'    => trim($data['penulis']),
            'tgl_submit' => self::tanggal($data['tgl_submit'] ?? null)
                ?? self::tanggal($amplop['terjadi_pada'] ?? null)
                ?? gmdate('Y-m-d'),
        ];
        //tanpa nilai, kolom tidak ditulis (publik). Nilai selain publik atau privat dianggap privat
        $v = $data['visibilitas'] ?? null;
        if ($v !== null) {
            $v = is_string($v) ? mb_strtolower(trim($v)) : '';
            $doc['visibilitas'] = in_array($v, self::VISIBILITAS, true) ? $v : 'privat';
        }
        return $doc;
    }

    private static function dariAnalisis(array $data): array
    {
        $sumber = $data['sumber'] ?? null;
        $hasil  = $data['hasil'] ?? null;
        if (!is_string($sumber) || !is_array($hasil)) {
            throw new \InvalidArgumentException('puisi.dianalisis harus punya sumber dan hasil.');
        }

        if ($sumber === 'auto-tagging') {
            $tag = [];
            foreach (is_array($hasil['keyword'] ?? null) ? $hasil['keyword'] : [] as $kata) {
                $kata = is_string($kata) ? mb_strtolower(trim($kata)) : '';
                if ($kata !== '') {
                    $tag[$kata] = true;
                }
            }
            $doc = ['tag' => array_slice(array_keys($tag), 0, self::TAG_MAKS)];
            $kategori = is_string($hasil['kategori'] ?? null) ? mb_strtolower(trim($hasil['kategori'])) : '';
            if ($kategori !== '') {
                $doc['kategori'] = $kategori;
            }
            return $doc;
        }

        if ($sumber === 'klasifikasi-genre') {
            $genre = is_string($hasil['genre'] ?? null) ? mb_strtolower(trim($hasil['genre'])) : '';
            return $genre !== '' ? ['genre' => $genre] : [];
        }

        return []; //analisis-emosi dan sumber lain tidak dicari
    }

    private static function tanggal(mixed $nilai): ?string
    {
        if (!is_string($nilai) || $nilai === '') {
            return null;
        }
        try {
            return (new \DateTimeImmutable($nilai))->format('Y-m-d');
        } catch (\Throwable) {
            return null;
        }
    }

    //Terapkan satu event ke OpenSearch: @return bool true bila indeks diubah, @throws \Throwable bila OpenSearch gagal, supaya consumer mengulang
    public static function terapkan(array $amplop, OpenSearch $os): bool
    {
        $r = self::rencana($amplop);
        if ($r === null) {
            return false;
        }
        //update ke indeks yang belum ada akan membuat indeks dengan mapping dinamis, jadi pastikan dulu
        Indeks::pastikan($os);
        [$kode, $badan] = $os->minta(
            'POST',
            '/' . Konfig::INDEKS . '/_update/' . $r['id'] . '?refresh=wait_for',
            ['doc' => $r['doc'], 'doc_as_upsert' => true]
        );
        if ($kode !== 200 && $kode !== 201) {
            throw new \RuntimeException('OpenSearch menolak update: HTTP ' . $kode . ' ' . json_encode($badan));
        }
        //"noop": isinya sudah sama (event ganda), indeks tidak berubah dan cache tidak perlu dibuang
        return ($badan['result'] ?? '') !== 'noop';
    }
}
