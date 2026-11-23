<?php
declare(strict_types=1);

namespace Auth;

/** Raised without touching the network while the auth-db circuit is open. */
final class DbUnavailable extends \RuntimeException
{
}
