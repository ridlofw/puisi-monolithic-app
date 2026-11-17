<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Pencarian\QueryBuilder;

final class QueryBuilderTest extends TestCase
{
    public function testQKosongMenjadiMatchAll(): void
    {
        $b = QueryBuilder::bangun();
        self::assertArrayHasKey('match_all', $b['query']['bool']['must'][0]);
        self::assertArrayHasKey('sort', $b);
    }

    public function testQTerisiMenjadiMultiMatchDenganBobotJudul(): void
    {
        $b  = QueryBuilder::bangun('  berlari  ');
        $mm = $b['query']['bool']['must'][0]['multi_match'];
        self::assertSame('berlari', $mm['query']);
        self::assertSame(['judul^2', 'isi', 'penulis'], $mm['fields']);
        self::assertArrayNotHasKey('sort', $b);
    }

    public function testFilterGenreDanTagHanyaBilaDiisi(): void
    {
        self::assertCount(1, QueryBuilder::bangun('x')['query']['bool']['filter']);

        $f = QueryBuilder::bangun('x', 'Pantun', ' Padi ')['query']['bool']['filter'];
        self::assertContains(['term' => ['genre' => 'pantun']], $f);
        self::assertContains(['term' => ['tag' => 'padi']], $f);
    }

    public function testPuisiPrivatTidakPernahLolos(): void
    {
        $privat = [['term' => ['visibilitas' => 'privat']]];
        $kasus = [
            QueryBuilder::bangun(),
            QueryBuilder::bangun('x'),
            QueryBuilder::bangun('', 'pantun'),
            QueryBuilder::bangun('x', 'syair', 'rindu', '3'),
            QueryBuilder::bangun('visibilitas:privat', 'privat', 'privat'),
        ];
        foreach ($kasus as $b) {
            self::assertSame($privat, $b['query']['bool']['must_not']);
            self::assertSame(['exists' => ['field' => 'tgl_submit']], $b['query']['bool']['filter'][0]);
        }
    }

    public function testHalamanMenentukanOffset(): void
    {
        self::assertSame(0, QueryBuilder::bangun('', '', '', '')['from']);
        self::assertSame(0, QueryBuilder::bangun('', '', '', '1')['from']);
        $b = QueryBuilder::bangun('', '', '', '3');
        self::assertSame(20, $b['from']);
        self::assertSame(10, $b['size']);
    }

    #[DataProvider('halBuruk')]
    public function testHalBurukDitolak(string $hal): void
    {
        $this->expectException(\InvalidArgumentException::class);
        QueryBuilder::bangun('x', '', '', $hal);
    }

    public static function halBuruk(): array
    {
        return ['negatif' => ['-1'], 'nol' => ['0'], 'huruf' => ['abc'], 'desimal' => ['1.5'],
                'kebesaran' => ['1001'], 'plus' => ['+2']];
    }

    public function testKutipDanGarisMiringHanyaMenjadiTeks(): void
    {
        $q = 'kutip " dan / miring \\ [] {} ( ) AND OR :';
        $b = QueryBuilder::bangun($q);
        self::assertSame($q, $b['query']['bool']['must'][0]['multi_match']['query']);
        self::assertNotFalse(json_encode($b));
    }

    public function testQDipotongDiBatas(): void
    {
        $b = QueryBuilder::bangun(str_repeat('a', 1000));
        self::assertSame(QueryBuilder::Q_MAKS, mb_strlen($b['query']['bool']['must'][0]['multi_match']['query']));
    }

    public function testHasilMengikutiKontrakDanMengEscapePotonganCadangan(): void
    {
        $respons = ['hits' => ['total' => ['value' => 2], 'hits' => [
            ['_id' => '7', '_source' => ['judul' => 'A', 'penulis' => 'P', 'genre' => 'syair', 'tag' => ['x'], 'isi' => 'a'],
             'highlight' => ['isi' => ['ada <mark>lari</mark>']]],
            ['_id' => '8', '_source' => ['judul' => 'B', 'penulis' => 'Q', 'isi' => '<script>x</script>']],
        ]]];
        $h = QueryBuilder::hasil($respons);
        self::assertSame(2, $h['total']);
        self::assertSame(7, $h['data'][0]['id']);
        self::assertSame('ada <mark>lari</mark>', $h['data'][0]['potongan']);
        self::assertSame('&lt;script&gt;x&lt;/script&gt;', $h['data'][1]['potongan']);
        self::assertSame(['id', 'judul', 'penulis', 'genre', 'tag', 'potongan'], array_keys($h['data'][0]));
    }

    public function testHasilKosongBilaResponsKosong(): void
    {
        self::assertSame(['data' => [], 'total' => 0], QueryBuilder::hasil([]));
    }
}
