<?php
// ============================================
// koneksi.php
// Koneksi ke MySQL menggunakan PDO
// ============================================

$db_host = 'localhost';
$db_name = 'puisi_db';
$db_user = 'root';
$db_pass = 'root';

try {
    $pdo = new PDO(
        "mysql:host=$db_host;dbname=$db_name;charset=utf8mb4",
        $db_user,
        $db_pass
    );
    // Aktifkan mode exception agar error PDO dilempar sebagai exception
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    // Gunakan prepared statement yang sebenarnya (bukan emulasi)
    $pdo->setAttribute(PDO::ATTR_EMULATE_PREPARES, false);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'pesan' => 'Koneksi database gagal: ' . $e->getMessage()]);
    exit;
}
