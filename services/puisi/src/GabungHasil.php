<?php
declare(strict_types=1);

namespace Puisi;

final class GabungHasil
{
    private const WAJIB_AMPLOP = ['event_id', 'tipe', 'versi', 'terjadi_pada', 'correlation_id', 'data'];

    /**
     * Validasi amplop event masuk dari q.puisi-hasil.
     * Melempar InvalidArgumentException bila pesan rusak agar diulang lalu masuk DLQ.
     *
     * @return array<string, mixed>
     */
    public static function validasiAmplop(string $bodyJson): array
    {
        $amplop = json_decode($bodyJson, true);
        if (!is_array($amplop)) {
            throw new \InvalidArgumentException('Body event bukan objek JSON yang sah.');
        }

        foreach (self::WAJIB_AMPLOP as $field) {
            if (!array_key_exists($field, $amplop)) {
                throw new \InvalidArgumentException("Field amplop {$field} tidak ada.");
            }
        }

        if (!is_array($amplop['data'])) {
            throw new \InvalidArgumentException('Field data pada amplop harus berupa objek JSON.');
        }

        $data = $amplop['data'];
        if (!isset($data['puisi_id']) || (!is_int($data['puisi_id']) && !ctype_digit((string) $data['puisi_id']))) {
            throw new \InvalidArgumentException('Field data.puisi_id harus berupa bilangan bulat.');
        }

        $tipe = (string) $amplop['tipe'];
        if ($tipe === 'puisi.dianalisis') {
            if (!isset($data['sumber']) || !is_string($data['sumber']) || trim($data['sumber']) === '') {
                throw new \InvalidArgumentException('Field data.sumber wajib ada pada puisi.dianalisis.');
            }
            if (!isset($data['hasil']) || !is_array($data['hasil'])) {
                throw new \InvalidArgumentException('Field data.hasil harus berupa objek JSON pada puisi.dianalisis.');
            }
        } elseif ($tipe === 'audio.siap') {
            if (!isset($data['url_audio']) || !is_string($data['url_audio']) || trim($data['url_audio']) === '') {
                throw new \InvalidArgumentException('Field data.url_audio wajib ada pada audio.siap.');
            }
        } else {
            throw new \InvalidArgumentException("Tipe event tidak didukung: {$tipe}");
        }

        return $amplop;
    }

    /**
     * Terapkan event hasil analisis atau audio secara murni dan idempoten.
     *
     * @param array<string, mixed> $keadaanLama
     * @param array<string, mixed> $amplop
     * @param list<string> $sumberWajib
     * @return array{
     *   kategori: ?string,
     *   keyword: ?string,
     *   file_gambar: ?string,
     *   status_analisis: string,
     *   status_audio: string,
     *   analisis: array<string, mixed>,
     *   url_audio: ?string
     * }
     */
    public static function terapkan(
        array $keadaanLama,
        array $amplop,
        array $sumberWajib = ['auto-tagging', 'klasifikasi-genre']
    ): array {
        $kategori       = isset($keadaanLama['kategori']) && trim((string) $keadaanLama['kategori']) !== ''
            ? trim((string) $keadaanLama['kategori'])
            : null;
        $keyword        = isset($keadaanLama['keyword']) && trim((string) $keadaanLama['keyword']) !== ''
            ? trim((string) $keadaanLama['keyword'])
            : null;
        $fileGambar     = isset($keadaanLama['file_gambar']) && trim((string) $keadaanLama['file_gambar']) !== ''
            ? trim((string) $keadaanLama['file_gambar'])
            : null;
        $statusAnalisis = (string) ($keadaanLama['status_analisis'] ?? 'diproses');
        $statusAudio    = (string) ($keadaanLama['status_audio'] ?? 'diproses');
        $urlAudio       = isset($keadaanLama['url_audio']) && trim((string) $keadaanLama['url_audio']) !== ''
            ? trim((string) $keadaanLama['url_audio'])
            : null;

        $analisis = [];
        if (isset($keadaanLama['analisis'])) {
            if (is_string($keadaanLama['analisis']) && $keadaanLama['analisis'] !== '') {
                $decoded = json_decode($keadaanLama['analisis'], true);
                if (is_array($decoded)) {
                    $analisis = $decoded;
                }
            } elseif (is_array($keadaanLama['analisis'])) {
                $analisis = $keadaanLama['analisis'];
            } elseif (is_object($keadaanLama['analisis'])) {
                $analisis = (array) $keadaanLama['analisis'];
            }
        }

        $tipe = (string) ($amplop['tipe'] ?? '');
        $data = is_array($amplop['data'] ?? null) ? $amplop['data'] : [];

        if ($tipe === 'puisi.dianalisis') {
            $sumber            = trim((string) $data['sumber']);
            $hasil             = is_array($data['hasil'] ?? null) ? $data['hasil'] : [];
            $analisis[$sumber] = $hasil;

            if ($sumber === 'auto-tagging') {
                if ($kategori === null && isset($hasil['kategori']) && is_string($hasil['kategori']) && trim($hasil['kategori']) !== '') {
                    $kategori = trim($hasil['kategori']);
                }
                if ($keyword === null && isset($hasil['keyword'])) {
                    if (is_array($hasil['keyword'])) {
                        $kataBersih = array_values(array_filter(
                            array_map(static fn($k): string => trim((string) $k), $hasil['keyword']),
                            static fn(string $k): bool => $k !== ''
                        ));
                        if ($kataBersih !== []) {
                            $keyword = implode(', ', $kataBersih);
                        }
                    } elseif (is_string($hasil['keyword']) && trim($hasil['keyword']) !== '') {
                        $keyword = trim($hasil['keyword']);
                    }
                }
            } elseif ($sumber === 'gambar-kutipan') {
                if ($fileGambar === null && isset($hasil['file_gambar']) && is_string($hasil['file_gambar']) && trim($hasil['file_gambar']) !== '') {
                    $fileGambar = trim($hasil['file_gambar']);
                }
            }

            $lengkap = true;
            foreach ($sumberWajib as $wajib) {
                if ($wajib !== '' && !array_key_exists($wajib, $analisis)) {
                    $lengkap = false;
                    break;
                }
            }

            if ($lengkap && $sumberWajib !== []) {
                $statusAnalisis = 'selesai';
            } elseif ($analisis !== []) {
                $statusAnalisis = 'sebagian';
            } else {
                $statusAnalisis = 'diproses';
            }
        } elseif ($tipe === 'audio.siap') {
            $urlAudio    = trim((string) $data['url_audio']);
            $statusAudio = 'selesai';
        }

        return [
            'kategori'        => $kategori,
            'keyword'         => $keyword,
            'file_gambar'     => $fileGambar,
            'status_analisis' => $statusAnalisis,
            'status_audio'    => $statusAudio,
            'analisis'        => $analisis,
            'url_audio'       => $urlAudio,
        ];
    }
}

