<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\Jwt;

final class JwtTest extends TestCase
{
    /** @return array<string, mixed> */
    private function bacaVektor(): array
    {
        $jalur = [
            dirname(__DIR__, 3) . '/kontrak/jwt-vektor.json',
            dirname(__DIR__) . '/tests/jwt-vektor.json',
        ];
        foreach ($jalur as $file) {
            if (is_readable($file)) {
                $isi = json_decode((string) file_get_contents($file), true);
                if (is_array($isi)) {
                    return $isi;
                }
            }
        }
        self::fail('Berkas kontrak/jwt-vektor.json tidak ditemukan.');
    }

    public function testTokenBenarDiterimaSesuaiVektorKontrak(): void
    {
        $v = $this->bacaVektor();
        $klaim = Jwt::verifikasi($v['token_benar'], $v['kunci'], 1790000000);
        self::assertSame($v['klaim']['sub'], $klaim['sub']);
        self::assertSame($v['klaim']['username'], $klaim['username']);
        self::assertSame($v['klaim']['nama'], $klaim['nama']);
        self::assertSame($v['klaim']['iat'], $klaim['iat']);
        self::assertSame($v['klaim']['exp'], $klaim['exp']);
    }

    public function testTokenKedaluwarsaDitolak(): void
    {
        $v = $this->bacaVektor();
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessage('kedaluwarsa');
        Jwt::verifikasi($v['token_kedaluwarsa'], $v['kunci'], 1790000000);
    }

    public function testTokenTandaTanganSalahDitolak(): void
    {
        $v = $this->bacaVektor();
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessage('Tanda tangan token tidak sah');
        Jwt::verifikasi($v['token_tanda_tangan_salah'], $v['kunci'], 1790000000);
    }

    public function testTokenDenganKunciBerbedaDitolak(): void
    {
        $v = $this->bacaVektor();
        $this->expectException(\InvalidArgumentException::class);
        Jwt::verifikasi($v['token_benar'], 'kunci-lain-yang-salah', 1790000000);
    }

    public function testTokenRusakDitolak(): void
    {
        $v = $this->bacaVektor();
        foreach (['', 'bukan.jwt', 'a.b.c', 'eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.abc'] as $rusak) {
            try {
                Jwt::verifikasi($rusak, $v['kunci'], 1790000000);
                self::fail("Token rusak seharusnya ditolak: {$rusak}");
            } catch (\InvalidArgumentException $e) {
                self::assertNotEmpty($e->getMessage());
            }
        }
    }

    public function testEkstrakBearerHeader(): void
    {
        self::assertSame('abc.def.ghi', Jwt::ekstrakBearer('Bearer abc.def.ghi'));
        self::assertSame('abc.def.ghi', Jwt::ekstrakBearer('bearer   abc.def.ghi  '));
        self::assertNull(Jwt::ekstrakBearer('Basic abc'));
        self::assertNull(Jwt::ekstrakBearer(null));
    }
}

