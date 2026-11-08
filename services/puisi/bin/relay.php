<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/vendor/autoload.php';

use Puisi\Amqp;
use Puisi\Db;
use Puisi\Konfig;
use Puisi\Log;
use Puisi\Metrik;

putenv('NAMA_LAYANAN=poem-relay');
$_ENV['NAMA_LAYANAN'] = 'poem-relay';

Metrik::mulaiServerDaemon('poem-relay', 'outbox', (int) Konfig::env('PORT_METRIK', '9100'));

$koneksiAmqp = null;
$kanalAmqp   = null;

$tutupAmqp = static function () use (&$koneksiAmqp, &$kanalAmqp): void {
    try {
        if ($kanalAmqp !== null) {
            $kanalAmqp->close();
        }
    } catch (\Throwable) {
    }
    try {
        if ($koneksiAmqp !== null) {
            $koneksiAmqp->close();
        }
    } catch (\Throwable) {
    }
    $kanalAmqp   = null;
    $koneksiAmqp = null;
};

Log::info('poem-relay dimulai');

while (true) {
    try {
        if ($kanalAmqp === null || $koneksiAmqp === null || !$koneksiAmqp->isConnected()) {
            $sambungan   = Amqp::sambung();
            $koneksiAmqp = $sambungan['koneksi'];
            $kanalAmqp   = $sambungan['kanal'];
            $kanalAmqp->confirm_select();
            Log::info('poem-relay terhubung ke RabbitMQ', ['node' => $sambungan['node']]);
        }

        $pdo = Db::tulis();
        $pdo->beginTransaction();

        // Kunci maksimal 20 baris yang belum terkirim; replika relay lain akan melewati baris yang terkunci
        $stmt = $pdo->query(
            'SELECT id, event_id, routing_key, payload
             FROM outbox
             WHERE terkirim_pada IS NULL
             ORDER BY id ASC
             LIMIT 20
             FOR UPDATE SKIP LOCKED'
        );
        $daftarBaris = $stmt ? $stmt->fetchAll() : [];

        if ($daftarBaris === []) {
            $pdo->commit();
            usleep(250_000); // 250 ms saat antrean outbox kosong
            continue;
        }

        $stmtUpdate = $pdo->prepare('UPDATE outbox SET terkirim_pada = NOW(3) WHERE id = :id');

        foreach ($daftarBaris as $baris) {
            $mulai       = microtime(true);
            $id          = (int) $baris['id'];
            $eventId     = (string) $baris['event_id'];
            $routingKey  = (string) $baris['routing_key'];
            $payloadJson = (string) $baris['payload'];
            $decoded     = json_decode($payloadJson, true);
            $cid         = is_array($decoded) && isset($decoded['correlation_id'])
                ? (string) $decoded['correlation_id']
                : $eventId;

            Amqp::terbitkan($kanalAmqp, $routingKey, $payloadJson, $eventId, $cid);
            $stmtUpdate->execute([':id' => $id]);
            Metrik::catatWorker('poem-relay', 'outbox', true, microtime(true) - $mulai);

            Log::info('outbox diterbitkan ke RabbitMQ', [
                'correlation_id' => $cid,
                'event_id'       => $eventId,
                'tipe'           => $routingKey,
            ]);
        }

        $pdo->commit();
    } catch (\Throwable $e) {
        Metrik::catatWorker('poem-relay', 'outbox', false, 0.0);
        if (isset($pdo) && $pdo instanceof \PDO && $pdo->inTransaction()) {
            try {
                $pdo->rollBack();
            } catch (\Throwable) {
            }
        }
        Db::putus();
        $tutupAmqp();
        Log::peringatan('gangguan pada poem-relay, mencoba lagi dalam 2 detik', [
            'error' => $e->getMessage(),
        ]);
        sleep(2);
    }
}
