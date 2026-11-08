<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\GabungHasil;

final class GabungHasilTest extends TestCase
{
    /** @return array<string, mixed> */
    private function keadaanAwal(?string $kategori = null, ?string $keyword = null, ?string $fileGambar = null): array
    {
        return [
            'kategori'        => $kategori,
            'keyword'         => $keyword,
            'file_gambar'     => $fileGambar,
            'status_analisis' => 'diproses',
            'status_audio'    => 'diproses',
            'analisis'        => [],
            'url_audio'       => null,
        ];
    }

    /**
     * @param array<string, mixed> $data
     * @return array<string, mixed>
     */
    private function buatAmplop(string $tipe, array $data): array
    {
        return [
            'event_id'       => 'eab12345-6789-4abc-8def-0123456789ab',
            'tipe'           => $tipe,
            'versi'          => 1,
            'terjadi_pada'   => '2026-11-08T15:00:00+00:00',
            'correlation_id' => 'cid-gabung',
            'data'           => $data,
        ];
    }

    public function testKategoriDanKeywordKosongDiisiOlehAutoTagging(): void
    {
        $awal  = $this->keadaanAwal(null, null);
        $event = $this->buatAmplop('puisi.dianalisis', [
            'puisi_id' => 1,
            'sumber'   => 'auto-tagging',
            'hasil'    => [
                'keyword'  => ['padi', 'pinang', 'hati', 'tenang'],
                'kategori' => 'sosial',
            ],
        ]);

        $baru = GabungHasil::terapkan($awal, $event);
        self::assertSame('sosial', $baru['kategori']);
        self::assertSame('padi, pinang, hati, tenang', $baru['keyword']);
        self::assertSame('sebagian', $baru['status_analisis']);
        self::assertArrayHasKey('auto-tagging', $baru['analisis']);
    }

    public function testKategoriDanKeywordManualTidakTertimpa(): void
    {
        $awal  = $this->keadaanAwal('nasihat', 'lisan, membaca');
        $event = $this->buatAmplop('puisi.dianalisis', [
            'puisi_id' => 3,
            'sumber'   => 'auto-tagging',
            'hasil'    => [
                'keyword'  => ['kata', 'lain'],
                'kategori' => 'alam',
            ],
        ]);

        $baru = GabungHasil::terapkan($awal, $event);
        self::assertSame('nasihat', $baru['kategori']);
        self::assertSame('lisan, membaca', $baru['keyword']);
        // Hasil asli worker tetap tersimpan di kolom analisis['auto-tagging']
        self::assertSame('alam', $baru['analisis']['auto-tagging']['kategori']);
    }

    public function testStatusMenjadiSelesaiSetelahSumberWajibLengkapDanIdempoten(): void
    {
        $keadaan = $this->keadaanAwal();

        $eventTag = $this->buatAmplop('puisi.dianalisis', [
            'puisi_id' => 1,
            'sumber'   => 'auto-tagging',
            'hasil'    => ['keyword' => ['padi', 'pinang'], 'kategori' => 'sosial'],
        ]);
        $eventGenre = $this->buatAmplop('puisi.dianalisis', [
            'puisi_id' => 1,
            'sumber'   => 'klasifikasi-genre',
            'hasil'    => ['genre' => 'pantun', 'skema_rima' => 'abab'],
        ]);

        $keadaan = GabungHasil::terapkan($keadaan, $eventTag);
        self::assertSame('sebagian', $keadaan['status_analisis']);

        $keadaan = GabungHasil::terapkan($keadaan, $eventGenre);
        self::assertSame('selesai', $keadaan['status_analisis']);
        self::assertSame('pantun', $keadaan['analisis']['klasifikasi-genre']['genre']);

        // Idempotensi: event yang sama diterapkan lagi tidak mengubah apa pun
        $keadaanUlang = GabungHasil::terapkan($keadaan, $eventGenre);
        self::assertSame($keadaan, $keadaanUlang);
    }

    public function testGambarKutipanMengisiFileGambarHanyaBilaKosong(): void
    {
        $awal = $this->keadaanAwal(null, null, null);
        $ev   = $this->buatAmplop('puisi.dianalisis', [
            'puisi_id' => 1,
            'sumber'   => 'gambar-kutipan',
            'hasil'    => ['file_gambar' => 'puisi_1.jpeg'],
        ]);
        $baru = GabungHasil::terapkan($awal, $ev);
        self::assertSame('puisi_1.jpeg', $baru['file_gambar']);

        $awalManual = $this->keadaanAwal(null, null, 'puisi_1767225600.jpeg');
        $baruManual = GabungHasil::terapkan($awalManual, $ev);
        self::assertSame('puisi_1767225600.jpeg', $baruManual['file_gambar']);
        self::assertSame('puisi_1.jpeg', $baruManual['analisis']['gambar-kutipan']['file_gambar']);
    }

    public function testAudioSiapMengisiUrlAudioDanStatusAudio(): void
    {
        $awal = $this->keadaanAwal();
        $ev   = $this->buatAmplop('audio.siap', [
            'puisi_id'     => 1,
            'url_audio'    => '/audio/puisi_1.mp3',
            'durasi_detik' => 11.8,
            'mesin'        => 'piper',
        ]);

        $baru = GabungHasil::terapkan($awal, $ev);
        self::assertSame('/audio/puisi_1.mp3', $baru['url_audio']);
        self::assertSame('selesai', $baru['status_audio']);
        self::assertSame(GabungHasil::terapkan($baru, $ev), $baru);
    }

    public function testValidasiAmplopMenolakPesanRusak(): void
    {
        foreach ([
            '{"bukan": "amplop"',
            '{"event_id":"1"}',
            json_encode($this->buatAmplop('puisi.dianalisis', ['puisi_id' => 'bukan-angka'])),
            json_encode($this->buatAmplop('puisi.dianalisis', ['puisi_id' => 1, 'sumber' => ''])),
            json_encode($this->buatAmplop('audio.siap', ['puisi_id' => 1])),
        ] as $rusak) {
            try {
                GabungHasil::validasiAmplop((string) $rusak);
                self::fail("Amplop rusak seharusnya ditolak: {$rusak}");
            } catch (\InvalidArgumentException $e) {
                self::assertNotEmpty($e->getMessage());
            }
        }
    }
}
