<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\Validasi;

final class ValidasiTest extends TestCase
{
    public function testKunciIdempotensiOpsionalDanUuidDiterima(): void
    {
        self::assertNull(Validasi::kunciIdempotensi(null));
        self::assertNull(Validasi::kunciIdempotensi('   '));
        self::assertSame('0b8f8a3e-5c1d-4e8a-9f00-1234567890ab',
            Validasi::kunciIdempotensi(' 0b8f8a3e-5c1d-4e8a-9f00-1234567890ab '));
    }

    public function testKunciIdempotensiTidakSahDitolak(): void
    {
        foreach (['pendek', str_repeat('a', 65), 'ada spasi di sini', "kunci'; DROP"] as $kunci) {
            try {
                Validasi::kunciIdempotensi($kunci);
                self::fail('Seharusnya ditolak: ' . $kunci);
            } catch (\InvalidArgumentException $e) {
                self::assertStringContainsString('Idempotency-Key', $e->getMessage());
            }
        }
    }

    public function testSidikSamaUntukIsiSamaDanBedaUntukIsiBeda(): void
    {
        $a = Validasi::puisiBaru(['judul' => 'Senja', 'isi' => 'Langit jingga', 'tgl_submit' => '2026-11-23']);
        $b = Validasi::puisiBaru(['judul' => ' Senja ', 'isi' => 'Langit jingga', 'tgl_submit' => '2026-11-23']);
        $c = Validasi::puisiBaru(['judul' => 'Senja', 'isi' => 'Langit kelabu', 'tgl_submit' => '2026-11-23']);
        self::assertSame(Validasi::sidik($a), Validasi::sidik($b));
        self::assertNotSame(Validasi::sidik($a), Validasi::sidik($c));
        self::assertSame(64, strlen(Validasi::sidik($a)));
    }

    public function testJudulAtauIsiKosongDitolak(): void
    {
        foreach ([
            ['judul' => '', 'isi' => 'Ada isi'],
            ['judul' => '   ', 'isi' => 'Ada isi'],
            ['judul' => 'Ada judul', 'isi' => ''],
            ['judul' => 'Ada judul', 'isi' => "  \n  "],
        ] as $kasus) {
            try {
                Validasi::puisiBaru($kasus);
                self::fail('Seharusnya gagal validasi saat judul/isi kosong.');
            } catch (\InvalidArgumentException $e) {
                self::assertStringContainsString('wajib diisi', $e->getMessage());
            }
        }
    }

    public function testKategoriKeywordDanGambarKosongMenjadiNull(): void
    {
        $hasil = Validasi::puisiBaru([
            'judul'       => 'Pagi di Ladang',
            'isi'         => "Pergi ke pasar membeli padi,\nPulang ke rumah membawa pinang.",
            'tgl_submit'  => '2026-11-08',
            'kategori'    => '',
            'keyword'     => '   ',
            'file_gambar' => '',
        ]);

        self::assertSame('Pagi di Ladang', $hasil['judul']);
        self::assertSame('2026-11-08', $hasil['tgl_submit']);
        self::assertNull($hasil['kategori']);
        self::assertNull($hasil['keyword']);
        self::assertNull($hasil['file_gambar']);
    }

    public function testPolaFileGambarSahDiterima(): void
    {
        $hasil = Validasi::puisiBaru([
            'judul'       => 'Senja',
            'isi'         => 'Senja merah di pelabuhan',
            'file_gambar' => 'puisi_1767225600123.jpeg',
        ]);
        self::assertSame('puisi_1767225600123.jpeg', $hasil['file_gambar']);
    }

    public function testPolaFileGambarSalahDitolak(): void
    {
        foreach ([
            '../etc/passwd',
            'puisi_abc.jpeg',
            'shell.php',
            'puisi_1234567890.png',
            'https://evil.com/puisi_1234567890.jpeg',
        ] as $salah) {
            try {
                Validasi::puisiBaru([
                    'judul'       => 'Senja',
                    'isi'         => 'Senja merah di pelabuhan',
                    'file_gambar' => $salah,
                ]);
                self::fail("Pola file_gambar salah seharusnya ditolak: {$salah}");
            } catch (\InvalidArgumentException $e) {
                self::assertStringContainsString('File gambar puisi tidak valid', $e->getMessage());
            }
        }
    }
}

