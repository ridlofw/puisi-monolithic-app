<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use Pencarian\Penangan;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class PenanganTest extends TestCase
{
    private static function amplop(string $tipe, array $data, array $tambahan = []): array
    {
        return Penangan::bacaAmplop(json_encode($tambahan + [
            'event_id' => 'e-1', 'tipe' => $tipe, 'versi' => 1,
            'terjadi_pada' => '2026-11-03T07:30:00+00:00', 'correlation_id' => 'c-1', 'data' => $data,
        ]));
    }

    private static function dibuat(array $ubah = []): array
    {
        // operator + mempertahankan sisi kiri, jadi $ubah harus di kiri agar menimpa nilai bawaan
        return $ubah + ['puisi_id' => 7, 'judul' => ' Pagi ', 'isi' => "baris 1\nbaris 2", 'penulis' => 'Sari',
                'visibilitas' => 'publik', 'kategori' => null, 'keyword' => null];
    }

    public function testDibuatMenulisHanyaKolomMilikSendiri(): void
    {
        $r = Penangan::rencana(self::amplop('puisi.dibuat', self::dibuat()));
        self::assertSame(7, $r['id']);
        self::assertSame(
            ['judul' => 'Pagi', 'isi' => "baris 1\nbaris 2", 'penulis' => 'Sari', 'tgl_submit' => '2026-11-03', 'visibilitas' => 'publik'],
            $r['doc']
        );
        //tag, kategori, genre milik event analisis. Kalau ikut ditulis, urutan event bisa menimpa hasil worker
        foreach (['tag', 'kategori', 'genre'] as $k) {
            self::assertArrayNotHasKey($k, $r['doc']);
        }
    }

    public function testDibuatTanpaVisibilitasSahTidakMenulisVisibilitas(): void
    {
        foreach ([null, 'rahasia', 'PUBLIK', true, ['publik']] as $v) {
            $r = Penangan::rencana(self::amplop('puisi.dibuat', self::dibuat(['visibilitas' => $v])));
            self::assertArrayNotHasKey('visibilitas', $r['doc'], 'nilai: ' . json_encode($v));
        }
        $data = self::dibuat();
        unset($data['visibilitas']);
        self::assertArrayNotHasKey('visibilitas', Penangan::rencana(self::amplop('puisi.dibuat', $data))['doc']);
    }

    public function testDibuatPrivatDitulisApaAdanya(): void
    {
        $r = Penangan::rencana(self::amplop('puisi.dibuat', self::dibuat(['visibilitas' => 'privat'])));
        self::assertSame('privat', $r['doc']['visibilitas']);
    }

    public function testTanggalDariDataBilaAda(): void
    {
        $r = Penangan::rencana(self::amplop('puisi.dibuat', self::dibuat(['tgl_submit' => '2026-10-01'])));
        self::assertSame('2026-10-01', $r['doc']['tgl_submit']);
    }

    public function testAutoTaggingMenulisTagDanKategoriSaja(): void
    {
        $r = Penangan::rencana(self::amplop('puisi.dianalisis', [
            'puisi_id' => 7, 'sumber' => 'auto-tagging',
            'hasil' => ['keyword' => ['Ladang', ' padi ', 'padi', '', 5], 'kategori' => 'Alam'],
        ]));
        self::assertSame(['tag' => ['ladang', 'padi'], 'kategori' => 'alam'], $r['doc']);
    }

    public function testGenreMenulisGenreSaja(): void
    {
        $r = Penangan::rencana(self::amplop('puisi.dianalisis', [
            'puisi_id' => 7, 'sumber' => 'klasifikasi-genre', 'hasil' => ['genre' => 'Pantun', 'skema_rima' => 'abab'],
        ]));
        self::assertSame(['genre' => 'pantun'], $r['doc']);
    }

    public function testAnalisisTidakPernahMenyentuhVisibilitas(): void
    {
        foreach ([
            ['sumber' => 'auto-tagging', 'hasil' => ['keyword' => ['x'], 'kategori' => 'a', 'visibilitas' => 'publik']],
            ['sumber' => 'klasifikasi-genre', 'hasil' => ['genre' => 'syair', 'visibilitas' => 'publik']],
        ] as $d) {
            $r = Penangan::rencana(self::amplop('puisi.dianalisis', ['puisi_id' => 7] + $d));
            self::assertArrayNotHasKey('visibilitas', $r['doc']);
        }
    }

    public function testSumberLainDanTipeLainDiabaikan(): void
    {
        self::assertNull(Penangan::rencana(self::amplop('puisi.dianalisis', [
            'puisi_id' => 7, 'sumber' => 'analisis-emosi', 'hasil' => ['sentimen' => ['skor' => 1, 'label' => 'positif']],
        ])));
        self::assertNull(Penangan::rencana(self::amplop('audio.siap', ['puisi_id' => 7])));
    }

    #[DataProvider('dataRusak')]
    public function testDataRusakDilempar(string $tipe, array $data): void
    {
        $this->expectException(\InvalidArgumentException::class);
        Penangan::rencana(self::amplop($tipe, $data));
    }

    public static function dataRusak(): array
    {
        return [
            'dibuat tanpa judul'   => ['puisi.dibuat', self::dibuat(['judul' => ''])],
            'dibuat tanpa isi'     => ['puisi.dibuat', self::dibuat(['isi' => '  '])],
            'dibuat penulis angka' => ['puisi.dibuat', self::dibuat(['penulis' => 3])],
            'analisis tanpa hasil' => ['puisi.dianalisis', ['puisi_id' => 7, 'sumber' => 'auto-tagging']],
            'analisis tanpa sumber' => ['puisi.dianalisis', ['puisi_id' => 7, 'hasil' => []]],
        ];
    }

    #[DataProvider('amplopRusak')]
    public function testAmplopRusakDitolak(string $badan): void
    {
        $this->expectException(\InvalidArgumentException::class);
        Penangan::bacaAmplop($badan);
    }

    public static function amplopRusak(): array
    {
        $ok = ['event_id' => 'e', 'tipe' => 'puisi.dibuat', 'data' => ['puisi_id' => 1]];
        return [
            'bukan json'        => ['{rusak'],
            'bukan objek'       => ['"teks"'],
            'tanpa event_id'    => [json_encode(array_diff_key($ok, ['event_id' => 1]))],
            'tanpa tipe'        => [json_encode(array_diff_key($ok, ['tipe' => 1]))],
            'tanpa data'        => [json_encode(array_diff_key($ok, ['data' => 1]))],
            'puisi_id string'   => [json_encode(['data' => ['puisi_id' => '1']] + $ok)],
            'puisi_id nol'      => [json_encode(['data' => ['puisi_id' => 0]] + $ok)],
            'puisi_id desimal'  => [json_encode(['data' => ['puisi_id' => 1.5]] + $ok)],
        ];
    }
}
