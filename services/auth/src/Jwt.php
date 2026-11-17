<?php
declare(strict_types=1);

namespace Auth;

final class Jwt
{
    private const HEADER = ['alg' => 'HS256', 'typ' => 'JWT'];
    private const CLAIM_ORDER = ['sub', 'username', 'nama', 'iat', 'exp'];

    public static function issue(array $user, string $secret, ?int $now = null, ?int $expiresAt = null): string
    {
        if ($secret === '') {
            throw new \InvalidArgumentException('Signing secret is empty.');
        }
        $issuedAt = $now ?? time();
        $claims = [
            'sub' => (string) $user['id'],
            'username' => (string) $user['username'],
            'nama' => (string) $user['nama'],
            'iat' => $issuedAt,
            'exp' => $expiresAt ?? ($issuedAt + 3600),
        ];
        $header = self::encodeJson(self::HEADER);
        $payload = self::encodeJson($claims);
        $signingInput = self::base64UrlEncode($header) . '.' . self::base64UrlEncode($payload);
        return $signingInput . '.' . self::base64UrlEncode(hash_hmac('sha256', $signingInput, $secret, true));
    }

    /** @return array{sub:string, username:string, nama:string, iat:int, exp:int} */
    public static function verify(string $token, string $secret, ?int $now = null): array
    {
        $parts = explode('.', trim($token));
        if (count($parts) !== 3 || $secret === '') {
            throw new \InvalidArgumentException('Malformed token or empty secret.');
        }
        [$headerPart, $claimsPart, $signaturePart] = $parts;
        $expected = self::base64UrlEncode(hash_hmac('sha256', $headerPart . '.' . $claimsPart, $secret, true));
        if (!hash_equals($expected, $signaturePart)) {
            throw new \InvalidArgumentException('Invalid token signature.');
        }
        $header = json_decode(self::base64UrlDecode($headerPart), true);
        $claims = json_decode(self::base64UrlDecode($claimsPart), true);
        if (!is_array($header) || ($header['alg'] ?? null) !== 'HS256' || !is_array($claims)) {
            throw new \InvalidArgumentException('Invalid JWT header or claims.');
        }
        if (array_keys($claims) !== self::CLAIM_ORDER) {
            throw new \InvalidArgumentException('JWT claims do not match the contract order.');
        }
        if (!is_string($claims['sub']) || !is_string($claims['username']) || !is_string($claims['nama'])
            || !is_int($claims['iat']) || !is_int($claims['exp']) || $claims['exp'] <= ($now ?? time())) {
            throw new \InvalidArgumentException('Invalid or expired JWT claims.');
        }
        return $claims;
    }

    private static function encodeJson(array $value): string
    {
        $json = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        return $json;
    }

    private static function base64UrlEncode(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private static function base64UrlDecode(string $value): string
    {
        if ($value === '' || preg_match('/^[A-Za-z0-9_-]+$/', $value) !== 1 || strlen($value) % 4 === 1) {
            throw new \InvalidArgumentException('Malformed base64url segment.');
        }
        $decoded = base64_decode(strtr($value . str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
        if ($decoded === false) {
            throw new \InvalidArgumentException('Malformed base64url segment.');
        }
        return $decoded;
    }
}
