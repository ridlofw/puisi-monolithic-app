<?php
declare(strict_types=1);

namespace Auth\Tests;

use Auth\Jwt;
use PHPUnit\Framework\TestCase;

final class JwtTest extends TestCase
{
    /** @return array<string, mixed> */
    private function vector(): array
    {
        $data = json_decode((string) file_get_contents(dirname(__DIR__, 3) . '/kontrak/jwt-vektor.json'), true);
        self::assertIsArray($data);
        return $data;
    }

    public function testIssuedTokenMatchesSharedVectorExactlyAndPoemVerifierAcceptsIt(): void
    {
        $vector = $this->vector();
        $token = Jwt::issue([
            'id' => $vector['klaim']['sub'],
            'username' => $vector['klaim']['username'],
            'nama' => $vector['klaim']['nama'],
        ], $vector['kunci'], $vector['klaim']['iat'], $vector['klaim']['exp']);
        self::assertSame($vector['token_benar'], $token);
        self::assertSame(
            $vector['klaim'],
            \Puisi\Jwt::verifikasi($token, $vector['kunci'], 1790000000)
        );
    }

    public function testVerifierRejectsExpiredAndIncorrectlySignedSharedVectors(): void
    {
        $vector = $this->vector();
        try {
            \Puisi\Jwt::verifikasi($vector['token_kedaluwarsa'], $vector['kunci'], 1790000000);
            self::fail('Expired shared token must be rejected.');
        } catch (\InvalidArgumentException) {
            self::assertTrue(true);
        }
        try {
            \Puisi\Jwt::verifikasi($vector['token_tanda_tangan_salah'], $vector['kunci'], 1790000000);
            self::fail('Bad-signature shared token must be rejected.');
        } catch (\InvalidArgumentException) {
            self::assertTrue(true);
        }
    }

    public function testTokenHasOneHourLifetimeAndOrderedClaims(): void
    {
        $token = Jwt::issue(['id' => 7, 'username' => 'uji', 'nama' => 'Uji'], 'secret', 1000);
        $parts = explode('.', $token);
        $claims = json_decode(base64_decode(strtr($parts[1] . '==', '-_', '+/')), true);
        self::assertSame(['sub', 'username', 'nama', 'iat', 'exp'], array_keys($claims));
        self::assertSame(4600, $claims['exp']);
        self::assertSame($claims, Jwt::verify($token, 'secret', 1001));
    }

    public function testAuthCodeDoesNotUsePhpSessionStateOrSetCookie(): void
    {
        $source = file_get_contents(dirname(__DIR__) . '/public/index.php');
        self::assertIsString($source);
        self::assertStringNotContainsString('session_start', $source);
        self::assertStringNotContainsString('$_SESSION', $source);
        self::assertStringNotContainsString('setcookie(', strtolower($source));
    }
}
