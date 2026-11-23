<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use Pencarian\Cache;
use Pencarian\QueryBuilder;
use PHPUnit\Framework\TestCase;

final class CacheTest extends TestCase
{
    public function testKeyBasiTidakBergantungVersi(): void
    {
        $p = ['q' => 'Pinang', 'genre' => '', 'tag' => '', 'hal' => 1];
        self::assertMatchesRegularExpression('/^cari:basi:[0-9a-f]{40}$/', Cache::kunciBasi($p));
        self::assertSame(Cache::kunciBasi($p), Cache::kunciBasi(['hal' => 1, 'tag' => '', 'genre' => '', 'q' => 'pinang']));
        self::assertSame(substr(Cache::kunci(3, $p), 8), substr(Cache::kunciBasi($p), 10));
    }

    public function testKeySamaUntukUrutanParameterBerbeda(): void
    {
        $a = Cache::kunci(3, ['q' => 'lari', 'genre' => 'pantun', 'tag' => '', 'hal' => 1]);
        $b = Cache::kunci(3, ['hal' => 1, 'tag' => '', 'genre' => 'pantun', 'q' => 'lari']);
        self::assertSame($a, $b);
    }

    public function testKeyBerubahSetelahVersiNaik(): void
    {
        $p = ['q' => 'lari', 'genre' => '', 'tag' => '', 'hal' => 1];
        self::assertNotSame(Cache::kunci(3, $p), Cache::kunci(4, $p));
    }

    public function testKeyMemuatVersiDanBerawalanCari(): void
    {
        self::assertMatchesRegularExpression('/^cari:v7:[0-9a-f]{40}$/', Cache::kunci(7, ['q' => 'x']));
    }

    public function testParameterBerbedaMenghasilkanKeyBerbeda(): void
    {
        $dasar = ['q' => 'lari', 'genre' => '', 'tag' => '', 'hal' => 1];
        $kunci = Cache::kunci(1, $dasar);
        foreach ([['q' => 'ibu'], ['genre' => 'syair'], ['tag' => 'pagi'], ['hal' => 2]] as $ubah) {
            self::assertNotSame($kunci, Cache::kunci(1, $ubah + $dasar));
        }
    }

    public function testHurufBesarKecilQTidakMempengaruhiKey(): void
    {
        $a = Cache::kunci(1, QueryBuilder::parameter('Berlari'));
        $b = Cache::kunci(1, QueryBuilder::parameter('  berlari '));
        self::assertSame($a, $b);
    }

    public function testParameterDibersihkanSamaDenganQuery(): void
    {
        self::assertSame(
            ['q' => 'Lari', 'genre' => 'pantun', 'tag' => '', 'hal' => 1],
            QueryBuilder::parameter('  Lari ', 'PANTUN', '  ', '')
        );
        self::assertSame(3, QueryBuilder::parameter('', '', '', '3')['hal']);
    }

    public function testParameterMenolakHalBuruk(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        QueryBuilder::parameter('x', '', '', '-1');
    }

    public function testTanpaRedisSemuaOperasiAmanDanKosong(): void
    {
        //alamat yang tidak mungkin terjangkau: pencarian harus jalan tanpa cache, bukan melempar
        putenv('REDIS_HOSTS=127.0.0.1:1');
        try {
            self::assertNull(Cache::versi());
            self::assertNull(Cache::ambil('cari:v1:x'));
            Cache::simpan('cari:v1:x', ['data' => []]);
            self::assertFalse(Cache::naikkanVersi());
        } finally {
            putenv('REDIS_HOSTS');
        }
    }
}
