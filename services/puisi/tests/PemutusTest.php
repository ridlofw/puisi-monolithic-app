<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\Pemutus;

final class PemutusTest extends TestCase
{
    private float $waktu = 1000.0;
    private string $folder;

    protected function setUp(): void
    {
        $this->folder = sys_get_temp_dir() . '/pemutus-uji-' . bin2hex(random_bytes(4));
    }

    protected function tearDown(): void
    {
        foreach (glob($this->folder . '/*') ?: [] as $f) {
            @unlink($f);
        }
        @rmdir($this->folder);
    }

    private function pemutus(): Pemutus
    {
        return new Pemutus($this->folder, 3, 10.0, fn (): float => $this->waktu);
    }

    public function testTetapTertutupDiBawahAmbang(): void
    {
        $p = $this->pemutus();
        $p->gagal('db-a');
        $p->gagal('db-a');
        self::assertSame(Pemutus::CLOSED, $p->status('db-a'));
        self::assertTrue($p->bolehCoba('db-a'));
    }

    public function testTerbukaSetelahTigaGagalBeruntunDanMenolakCepat(): void
    {
        $p = $this->pemutus();
        for ($i = 0; $i < 3; $i++) {
            $p->gagal('db-a');
        }
        self::assertSame(Pemutus::OPEN, $p->status('db-a'));
        self::assertFalse($p->bolehCoba('db-a'));
        self::assertTrue($p->bolehCoba('db-b'), 'tujuan lain tidak ikut terputus');
    }

    public function testSuksesMengosongkanHitungan(): void
    {
        $p = $this->pemutus();
        $p->gagal('db-a');
        $p->gagal('db-a');
        $p->sukses('db-a');
        $p->gagal('db-a');
        self::assertSame(Pemutus::CLOSED, $p->status('db-a'));
    }

    public function testHalfOpenHanyaSatuUjiLaluTertutupBilaSukses(): void
    {
        $p = $this->pemutus();
        for ($i = 0; $i < 3; $i++) {
            $p->gagal('db-a');
        }
        $this->waktu += 10.5;
        self::assertTrue($p->bolehCoba('db-a'), 'satu uji diizinkan setelah jeda');
        self::assertSame(Pemutus::HALF_OPEN, $p->status('db-a'));
        self::assertFalse($p->bolehCoba('db-a'), 'pemanggil kedua ditolak selama uji berjalan');
        $p->sukses('db-a');
        self::assertSame(Pemutus::CLOSED, $p->status('db-a'));
        self::assertTrue($p->bolehCoba('db-a'));
    }

    public function testHalfOpenGagalMembukaLagi(): void
    {
        $p = $this->pemutus();
        for ($i = 0; $i < 3; $i++) {
            $p->gagal('db-a');
        }
        $this->waktu += 11;
        self::assertTrue($p->bolehCoba('db-a'));
        $p->gagal('db-a');
        self::assertSame(Pemutus::OPEN, $p->status('db-a'));
        self::assertFalse($p->bolehCoba('db-a'));
    }

    public function testKeadaanDibagiAntarInstansDiFolderSama(): void
    {
        $a = $this->pemutus();
        $b = $this->pemutus();
        for ($i = 0; $i < 3; $i++) {
            $a->gagal('db-a');
        }
        self::assertFalse($b->bolehCoba('db-a'), 'proses lain membaca sirkuit yang sama');
    }
}
