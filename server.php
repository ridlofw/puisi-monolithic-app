<?php
// ============================================
// server.php
// Backend Monolitik — Single-Path Routing
// Semua aksi ditentukan via parameter 'aksi'
// ============================================

// 1. Mulai session di baris paling atas (Server-Side Local Session)
session_start();

// 2. Header agar response selalu JSON
header('Content-Type: application/json; charset=utf-8');

// 3. Header CORS agar fetch() dari file HTML bisa mengakses
//    (diperlukan saat development lokal; di production bisa disesuaikan)
header('Access-Control-Allow-Origin: ' . ($_SERVER['HTTP_ORIGIN'] ?? '*'));
header('Access-Control-Allow-Credentials: true');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

// Tangani preflight OPTIONS
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// 4. Sertakan koneksi database
require_once __DIR__ . '/koneksi.php';

// 5. Tentukan aksi dari parameter GET
$aksi = $_GET['aksi'] ?? '';

// 6. Fungsi pembantu untuk mengirim respons JSON
function kirimRespon($status, $pesan, $data = null) {
    $respon = ['status' => $status, 'pesan' => $pesan];
    if ($data !== null) {
        $respon['data'] = $data;
    }
    echo json_encode($respon, JSON_UNESCAPED_UNICODE);
    exit;
}

// 7. Fungsi pembantu untuk membaca body JSON dari POST request
function bacaInputJSON() {
    $raw = file_get_contents('php://input');
    $data = json_decode($raw, true);
    if ($data === null) {
        // Fallback ke $_POST jika bukan JSON (form-encoded)
        return $_POST;
    }
    return $data;
}

// 8. Fungsi untuk mengecek apakah user sudah login
function cekLogin() {
    if (!isset($_SESSION['user_id'])) {
        http_response_code(401);
        kirimRespon('error', 'Anda belum login. Silakan login terlebih dahulu.');
    }
}

// ============================================
// ROUTING BERDASARKAN AKSI
// ============================================

switch ($aksi) {

    // ------------------------------------------
    // REGISTER
    // ------------------------------------------
    case 'register':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            http_response_code(405);
            kirimRespon('error', 'Method tidak diizinkan. Gunakan POST.');
        }

        $input = bacaInputJSON();

        $username = trim($input['username'] ?? '');
        $password = $input['password'] ?? '';
        $nama     = trim($input['nama'] ?? '');
        $no_id    = trim($input['no_id'] ?? '');

        // Validasi input
        if ($username === '' || $password === '' || $nama === '' || $no_id === '') {
            http_response_code(400);
            kirimRespon('error', 'Semua field wajib diisi (username, password, nama, no_id).');
        }

        // Cek apakah username sudah terdaftar
        try {
            $stmt = $pdo->prepare('SELECT id FROM users WHERE username = :username');
            $stmt->execute([':username' => $username]);

            if ($stmt->fetch()) {
                http_response_code(409);
                kirimRespon('error', 'Username sudah terdaftar. Gunakan username lain.');
            }

            // Hash password
            $hashedPassword = password_hash($password, PASSWORD_DEFAULT);

            // INSERT user baru
            $stmt = $pdo->prepare(
                'INSERT INTO users (username, password, nama, no_id) VALUES (:username, :password, :nama, :no_id)'
            );
            $stmt->execute([
                ':username' => $username,
                ':password' => $hashedPassword,
                ':nama'     => $nama,
                ':no_id'    => $no_id
            ]);

            kirimRespon('sukses', 'Registrasi berhasil. Silakan login.');

        } catch (PDOException $e) {
            http_response_code(500);
            kirimRespon('error', 'Gagal registrasi: ' . $e->getMessage());
        }
        break;

    // ------------------------------------------
    // LOGIN
    // ------------------------------------------
    case 'login':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            http_response_code(405);
            kirimRespon('error', 'Method tidak diizinkan. Gunakan POST.');
        }

        $input = bacaInputJSON();

        $username = trim($input['username'] ?? '');
        $password = $input['password'] ?? '';

        if ($username === '' || $password === '') {
            http_response_code(400);
            kirimRespon('error', 'Username dan password wajib diisi.');
        }

        try {
            $stmt = $pdo->prepare('SELECT id, username, nama, password FROM users WHERE username = :username');
            $stmt->execute([':username' => $username]);
            $user = $stmt->fetch(PDO::FETCH_ASSOC);

            if (!$user || !password_verify($password, $user['password'])) {
                http_response_code(401);
                kirimRespon('error', 'Username atau password salah.');
            }

            // Simpan data ke session (Server-Side Local Session)
            $_SESSION['user_id']  = $user['id'];
            $_SESSION['username'] = $user['username'];
            $_SESSION['nama']     = $user['nama'];

            kirimRespon('sukses', 'Login berhasil.', [
                'user_id'  => $user['id'],
                'username' => $user['username'],
                'nama'     => $user['nama']
            ]);

        } catch (PDOException $e) {
            http_response_code(500);
            kirimRespon('error', 'Gagal login: ' . $e->getMessage());
        }
        break;

    // ------------------------------------------
    // LOGOUT
    // ------------------------------------------
    case 'logout':
        session_unset();
        session_destroy();
        kirimRespon('sukses', 'Logout berhasil.');
        break;

    // ------------------------------------------
    // CEK STATUS SESSION
    // ------------------------------------------
    case 'cek_session':
        if (isset($_SESSION['user_id'])) {
            kirimRespon('sukses', 'Session aktif.', [
                'user_id'  => $_SESSION['user_id'],
                'username' => $_SESSION['username'],
                'nama'     => $_SESSION['nama']
            ]);
        } else {
            kirimRespon('error', 'Belum login.');
        }
        break;

    // ------------------------------------------
    // SUBMIT PUISI
    // ------------------------------------------
    case 'submit_puisi':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            http_response_code(405);
            kirimRespon('error', 'Method tidak diizinkan. Gunakan POST.');
        }

        // Cek session terlebih dahulu
        cekLogin();

        $input = bacaInputJSON();

        $judul      = trim($input['judul'] ?? '');
        $isi        = trim($input['isi'] ?? '');
        $tgl_submit = trim($input['tgl_submit'] ?? date('Y-m-d'));
        $kategori   = trim($input['kategori'] ?? '');
        $keyword    = trim($input['keyword'] ?? '');

        if ($judul === '' || $isi === '' || $kategori === '' || $keyword === '') {
            http_response_code(400);
            kirimRespon('error', 'Semua field puisi wajib diisi (judul, isi, kategori, keyword).');
        }

        try {
            $stmt = $pdo->prepare(
                'INSERT INTO puisi (user_id, judul, tgl_submit, isi, kategori, keyword)
                 VALUES (:user_id, :judul, :tgl_submit, :isi, :kategori, :keyword)'
            );
            $stmt->execute([
                ':user_id'    => $_SESSION['user_id'],
                ':judul'      => $judul,
                ':tgl_submit' => $tgl_submit,
                ':isi'        => $isi,
                ':kategori'   => $kategori,
                ':keyword'    => $keyword
            ]);

            kirimRespon('sukses', 'Puisi berhasil disimpan.');

        } catch (PDOException $e) {
            http_response_code(500);
            kirimRespon('error', 'Gagal menyimpan puisi: ' . $e->getMessage());
        }
        break;

    // ------------------------------------------
    // DAFTAR PUISI
    // ------------------------------------------
    case 'daftar_puisi':
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            http_response_code(405);
            kirimRespon('error', 'Method tidak diizinkan. Gunakan GET.');
        }

        // Cek session terlebih dahulu
        cekLogin();

        try {
            $stmt = $pdo->prepare(
                'SELECT p.id, p.judul, p.tgl_submit, p.isi, p.kategori, p.keyword, u.nama AS penulis
                 FROM puisi p
                 INNER JOIN users u ON p.user_id = u.id
                 ORDER BY p.tgl_submit DESC'
            );
            $stmt->execute();
            $daftarPuisi = $stmt->fetchAll(PDO::FETCH_ASSOC);

            kirimRespon('sukses', 'Daftar puisi berhasil dimuat.', $daftarPuisi);

        } catch (PDOException $e) {
            http_response_code(500);
            kirimRespon('error', 'Gagal memuat daftar puisi: ' . $e->getMessage());
        }
        break;

    // ------------------------------------------
    // AKSI TIDAK DIKENALI
    // ------------------------------------------
    default:
        http_response_code(400);
        kirimRespon('error', 'Aksi tidak dikenali. Gunakan parameter ?aksi=register|login|logout|cek_session|submit_puisi|daftar_puisi');
        break;
}
