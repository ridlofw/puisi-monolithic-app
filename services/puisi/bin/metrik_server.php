<?php
declare(strict_types=1);

$uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
if ($uri !== '/metrics') {
    http_response_code(404);
    exit;
}

header('Content-Type: text/plain; version=0.0.4; charset=utf-8');
if (is_readable('/tmp/metrik.prom')) {
    readfile('/tmp/metrik.prom');
} else {
    echo "# HELP worker_pesan_diproses_total Pesan yang selesai diproses dan di-ack.\n";
    echo "# TYPE worker_pesan_diproses_total counter\n";
    echo "worker_pesan_diproses_total{worker=\"poem-daemon\",queue=\"outbox\"} 0\n";
}

