<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use Pencarian\Ulang;
use PHPUnit\Framework\TestCase;

final class UlangTest extends TestCase
{
    public function testEksponensialDenganBatasEmpatDetik(): void
    {
        $tengah = static fn (float $a, float $b): float => ($a + $b) / 2;
        $hasil  = array_map(static fn (int $n): int => Ulang::jedaMikro($n, $tengah), [2, 3, 4, 5]);
        $this->assertSame([1_000_000, 2_000_000, 4_000_000, 4_000_000], $hasil);
    }

    public function testJitterDalamRentangDuaPuluhPersen(): void
    {
        for ($i = 0; $i < 200; $i++) {
            $j = Ulang::jedaMikro(3);
            $this->assertGreaterThanOrEqual(1_600_000, $j);
            $this->assertLessThanOrEqual(2_400_000, $j);
        }
    }

    public function testJitterMenyebarJadwal(): void
    {
        $nilai = [];
        for ($i = 0; $i < 50; $i++) {
            $nilai[Ulang::jedaMikro(3)] = true;
        }
        $this->assertGreaterThan(10, count($nilai));
    }
}
