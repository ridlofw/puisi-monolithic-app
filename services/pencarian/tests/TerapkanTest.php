<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use Pencarian\OpenSearch;
use Pencarian\Penangan;
use PHPUnit\Framework\TestCase;

final class TerapkanTest extends TestCase
{
    //OpenSearch palsu: mencatat permintaan dan menjawab update dengan hasil yang ditentukan
    private static function palsu(int $kodeUpdate, string $hasil): OpenSearch
    {
        return new class ($kodeUpdate, $hasil) extends OpenSearch {
            /** @var list<string> */
            public array $jalur = [];

            public function __construct(private int $kodeUpdate, private string $hasil)
            {
                parent::__construct('http://tidak-dipakai');
            }

            public function minta(string $metode, string $jalur, ?array $badan = null): array
            {
                $this->jalur[] = $metode . ' ' . $jalur;
                if ($metode === 'HEAD') {
                    return [200, []]; 
                }
                return [$this->kodeUpdate, ['result' => $this->hasil]];
            }
        };
    }

    private static function amplop(): array
    {
        return Penangan::bacaAmplop(json_encode([
            'event_id' => 'e', 'tipe' => 'puisi.dianalisis', 'correlation_id' => 'c',
            'data' => ['puisi_id' => 9, 'sumber' => 'klasifikasi-genre', 'hasil' => ['genre' => 'syair']],
        ]));
    }

    public function testUpdateBerubahMengembalikanTrueDanMenungguRefresh(): void
    {
        foreach (['updated', 'created'] as $hasil) {
            $os = self::palsu(200, $hasil);
            self::assertTrue(Penangan::terapkan(self::amplop(), $os));
            // retry_on_conflict karena beberapa consumer paralel bisa memperbarui dokumen yang sama bersamaan
        self::assertContains('POST /puisi/_update/9?refresh=wait_for&retry_on_conflict=3', $os->jalur);
        }
    }

    public function testNoopTidakDianggapBerubah(): void
    {
        self::assertFalse(Penangan::terapkan(self::amplop(), self::palsu(200, 'noop')));
    }

    public function testEventTanpaDampakTidakMenyentuhOpenSearch(): void
    {
        $os = self::palsu(200, 'updated');
        $amplop = Penangan::bacaAmplop(json_encode([
            'event_id' => 'e', 'tipe' => 'audio.siap', 'data' => ['puisi_id' => 9],
        ]));
        self::assertFalse(Penangan::terapkan($amplop, $os));
        self::assertSame([], $os->jalur);
    }

    public function testPenolakanOpenSearchDilempar(): void
    {
        $this->expectException(\RuntimeException::class);
        Penangan::terapkan(self::amplop(), self::palsu(500, ''));
    }
}
