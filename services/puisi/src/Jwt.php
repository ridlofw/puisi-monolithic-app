<?php
declare(strict_types=1);

namespace Puisi;

final class Jwt
{
    public static function b64UrlEncode(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }

    public static function b64UrlDecode(string $teks): ?string
    {
        if ($teks === '' || !preg_match('/^[A-Za-z0-9_-]+$/', $teks)) {
            return null;
        }
        $sisa = strlen($teks) % 4;
        if ($sisa === 1) {
            return null;
        }
        if ($sisa > 0) {
            $teks .= str_repeat('=', 4 - $sisa);
        }
        $hasil = base64_decode(strtr($teks, '-_', '+/'), true);
        return $hasil === false ? null : $hasil;
    }

    /**
     * Verifikasi token JWT HS256 tanpa pustaka.
     * Tanda tangan dihitung langsung atas dua segmen base64url apa adanya sesuai kontrak/README.md.
     *
     * @return array{sub: string, username: string, nama: string, iat: int, exp: int}
     */
    public static function verifikasi(string $token, string $kunci, ?int $waktuSekarang = null): array
    {
        $token = trim($token);
        if ($token === '' || $kunci === '') {
            throw new \InvalidArgumentException('Token atau kunci kosong.');
        }

        $segmen = explode('.', $token);
        if (count($segmen) !== 3) {
            throw new \InvalidArgumentException('Format token JWT tidak sah.');
        }

        [$headerB64, $klaimB64, $tandaB64] = $segmen;
        if ($headerB64 === '' || $klaimB64 === '' || $tandaB64 === '') {
            throw new \InvalidArgumentException('Segmen token JWT kosong.');
        }

        // Hitung HMAC-SHA256 langsung atas segmen base64url apa adanya (jangan serialisasi ulang JSON)
        $kepala = $headerB64 . '.' . $klaimB64;
        $tandaHarapan = self::b64UrlEncode(hash_hmac('sha256', $kepala, $kunci, true));
        if (!hash_equals($tandaHarapan, $tandaB64)) {
            throw new \InvalidArgumentException('Tanda tangan token tidak sah.');
        }

        $headerRaw = self::b64UrlDecode($headerB64);
        $klaimRaw  = self::b64UrlDecode($klaimB64);
        if ($headerRaw === null || $klaimRaw === null) {
            throw new \InvalidArgumentException('Segmen base64url tidak sah.');
        }

        $header = json_decode($headerRaw, true);
        $klaim  = json_decode($klaimRaw, true);
        if (!is_array($header) || ($header['alg'] ?? '') !== 'HS256') {
            throw new \InvalidArgumentException('Algoritma JWT harus HS256.');
        }
        if (!is_array($klaim)) {
            throw new \InvalidArgumentException('Payload klaim bukan objek JSON.');
        }

        foreach (['sub', 'username', 'nama', 'iat', 'exp'] as $wajib) {
            if (!array_key_exists($wajib, $klaim)) {
                throw new \InvalidArgumentException("Klaim {$wajib} tidak ada.");
            }
        }

        if (!is_string($klaim['sub']) || trim($klaim['sub']) === '') {
            throw new \InvalidArgumentException('Klaim sub harus string tidak kosong.');
        }
        if (!is_string($klaim['username']) || !is_string($klaim['nama']) || trim($klaim['nama']) === '') {
            throw new \InvalidArgumentException('Klaim username dan nama harus string.');
        }
        if (!is_int($klaim['exp']) && !is_numeric($klaim['exp'])) {
            throw new \InvalidArgumentException('Klaim exp tidak sah.');
        }

        $sekarang = $waktuSekarang ?? time();
        if ((int) $klaim['exp'] <= $sekarang) {
            throw new \InvalidArgumentException('Token sudah kedaluwarsa.');
        }

        return [
            'sub'      => (string) $klaim['sub'],
            'username' => (string) $klaim['username'],
            'nama'     => (string) $klaim['nama'],
            'iat'      => (int) $klaim['iat'],
            'exp'      => (int) $klaim['exp'],
        ];
    }

    public static function ekstrakBearer(?string $headerAuth): ?string
    {
        if ($headerAuth === null) {
            return null;
        }
        if (preg_match('/^\s*Bearer\s+(\S+)\s*$/i', $headerAuth, $cocok)) {
            return $cocok[1];
        }
        return null;
    }
}

