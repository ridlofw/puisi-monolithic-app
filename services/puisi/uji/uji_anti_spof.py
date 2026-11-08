#!/usr/bin/env python3
"""Skrip otomatis uji ketahanan Zero-SPOF pada layanan puisi (R1-R3).

Menguji 6 skenario kegagalan infrastruktur secara berurutan dan memastikan
seluruh container dipulihkan kembali pada akhir pengujian:
  1. 1 replika poem-service mati -> POST & GET /api/puisi tetap 202/200.
  2. 1 MySQL Router (poem-db-router-1) mati -> POST & GET tetap 202/200 via router-2.
  3. Node Primary MySQL InnoDB Cluster mati -> failover otomatis ke Secondary, POST & GET tetap 202/200.
  4. Redis mati -> GET /api/puisi tetap 200 dengan X-Cache-Layer: db.
  5. 1 node RabbitMQ (rabbitmq-2) mati -> event outbox tetap terkirim ke quorum cluster.
  6. Seluruh node RabbitMQ (1..3) mati -> POST tetap 202 (disimpan di outbox),
     dan otomatis terkirim begitu RabbitMQ menyala kembali.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE_URL = "http://localhost"


def jalankan(cmd, check=True):
    return subprocess.run(
        cmd,
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=check,
    )


def ambil_token():
    hasil = jalankan([sys.executable, "scripts/token_uji.py"])
    return hasil.stdout.strip()


def http_req(method, path, token=None, body=None, timeout=15):
    url = f"{BASE_URL}{path}"
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    for percobaan in range(3):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                isi = resp.read().decode("utf-8", errors="replace")
                return resp.status, dict(resp.headers), json.loads(isi) if isi else {}
        except urllib.error.HTTPError as e:
            isi = e.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(isi)
            except Exception:
                parsed = {"raw": isi}
            if e.code >= 500 and percobaan < 2:
                time.sleep(1)
                continue
            return e.code, dict(e.headers), parsed
        except Exception:
            if percobaan == 2:
                raise
            time.sleep(1)
    return 0, {}, {}


def kirim_puisi_uji(token, label):
    payload = {
        "judul": f"Uji Anti SPOF - {label}",
        "isi": "Kalau ada sumur di ladang\nBoleh kita menumpang mandi",
    }
    for _ in range(4):
        try:
            kode, hdr, data = http_req("POST", "/api/puisi", token=token, body=payload)
            if kode == 202 and isinstance(data.get("data"), dict) and data["data"].get("id"):
                return kode, hdr, int(data["data"]["id"])
        except Exception:
            pass
        time.sleep(2)
    return 0, {}, 0


def cari_node_primary():
    for node in ("poem-db-1", "poem-db-2", "poem-db-3"):
        r = jalankan(
            [
                "docker", "compose", "--profile", "puisi",
                "exec", "-T", node,
                "mysql", "-uroot", "-ppoem", "-N", "-s",
                "-e", "SELECT @@super_read_only;",
            ],
            check=False,
        )
        if r.returncode == 0 and r.stdout.strip() == "0":
            return node
    return "poem-db-1"


def tunggu_outbox_terkirim(puisi_id, batas_detik=30):
    node_cek = cari_node_primary()
    akhir = time.time() + batas_detik
    while time.time() < akhir:
        r = jalankan(
            [
                "docker", "compose", "--profile", "puisi",
                "exec", "-T", node_cek,
                "mysql", "-uroot", "-ppoem", "-N", "-s", "poem_db",
                "-e",
                f"SELECT COUNT(*) FROM outbox WHERE JSON_EXTRACT(payload, '$.data.puisi_id') = {puisi_id} AND terkirim_pada IS NOT NULL;",
            ],
            check=False,
        )
        if r.returncode == 0 and r.stdout.strip().isdigit() and int(r.stdout.strip()) >= 1:
            return True
        time.sleep(1)
    return False


def pulihkan_semua():
    jalankan(
        [
            "docker", " start",
            "puisi-poem-service-1",
            "puisi-poem-service-2",
            "puisi-poem-db-router-1-1",
            "puisi-poem-db-router-2-1",
            "puisi-poem-db-1-1",
            "puisi-poem-db-2-1",
            "puisi-poem-db-3-1",
            "puisi-redis-1",
            "puisi-rabbitmq-1-1",
            "puisi-rabbitmq-2-1",
            "puisi-rabbitmq-3-1",
        ],
        check=False,
    )
    jalankan(["docker", "compose", "--profile", "puisi", "start", "poem-db-cluster-init"], check=False)


def main():
    token = ambil_token()
    hasil_skenario = []

    def catat(nama, lulus, ket=""):
        status = "LULUS" if lulus else "GAGAL"
        hasil_skenario.append((nama, lulus, ket))
        print(f"[{status}] {nama}" + (f" -- {ket}" if ket else ""))

    try:
        # 1. Matikan 1 replika poem-service
        jalankan(["docker", "stop", "puisi-poem-service-1"], check=False)
        kode_post, _, pid1 = kirim_puisi_uji(token, "Skenario 1 (1 poem-service mati)")
        kode_get, _, _ = http_req("GET", f"/api/puisi/{pid1}")
        catat(
            "Skenario 1: 1 replika poem-service mati",
            kode_post == 202 and kode_get == 200,
            f"POST={kode_post}, GET={kode_get}, id={pid1}",
        )
        jalankan(["docker", "start", "puisi-poem-service-1"], check=False)

        # 2. Matikan poem-db-router-1
        jalankan(["docker", "stop", "puisi-poem-db-router-1-1"], check=False)
        kode_post, _, pid2 = kirim_puisi_uji(token, "Skenario 2 (router-1 mati)")
        kode_get, _, _ = http_req("GET", f"/api/puisi/{pid2}")
        catat(
            "Skenario 2: poem-db-router-1 mati (failover ke router-2)",
            kode_post == 202 and kode_get == 200,
            f"POST={kode_post}, GET={kode_get}, id={pid2}",
        )
        jalankan(["docker", "start", "puisi-poem-db-router-1-1"], check=False)

        # 3. Matikan node Primary MySQL InnoDB Cluster
        primary_awal = cari_node_primary()
        container_primary = f"puisi-{primary_awal}-1"
        jalankan(["docker", "stop", container_primary], check=False)
        time.sleep(6)  # Beri waktu pemilihan Primary baru oleh Group Replication
        primary_baru = cari_node_primary()
        kode_post, _, pid3 = kirim_puisi_uji(token, f"Skenario 3 ({primary_awal} mati)")
        kode_get, _, _ = http_req("GET", f"/api/puisi/{pid3}")
        catat(
            f"Skenario 3: Primary {primary_awal} mati -> failover ke {primary_baru}",
            kode_post == 202 and kode_get == 200 and primary_baru != primary_awal,
            f"POST={kode_post}, GET={kode_get}, primary_baru={primary_baru}, id={pid3}",
        )
        jalankan(["docker", "start", container_primary], check=False)
        time.sleep(4)
        jalankan(["docker", "compose", "--profile", "puisi", "start", "poem-db-cluster-init"], check=False)

        # 4. Matikan Redis -> degradasi aman ke DB
        jalankan(["docker", "stop", "puisi-redis-1"], check=False)
        kode_get, hdr_get, _ = http_req("GET", f"/api/puisi?hal=1&per_hal=5&_cb={int(time.time())}")
        layer = hdr_get.get("X-Cache-Layer", hdr_get.get("x-cache-layer", ""))
        catat(
            "Skenario 4: Redis mati -> degradasi aman ke DB",
            kode_get == 200 and layer == "db",
            f"GET={kode_get}, X-Cache-Layer={layer}",
        )
        jalankan(["docker", "start", "puisi-redis-1"], check=False)

        # 5. Matikan 1 node RabbitMQ (rabbitmq-2) -> quorum tetap jalan
        jalankan(["docker", "stop", "puisi-rabbitmq-2-1"], check=False)
        kode_post, _, pid5 = kirim_puisi_uji(token, "Skenario 5 (rabbitmq-2 mati)")
        terkirim5 = tunggu_outbox_terkirim(pid5, batas_detik=20)
        catat(
            "Skenario 5: 1 node RabbitMQ (rabbitmq-2) mati",
            kode_post == 202 and terkirim5,
            f"POST={kode_post}, outbox_terkirim={terkirim5}, id={pid5}",
        )
        jalankan(["docker", "start", "puisi-rabbitmq-2-1"], check=False)
        time.sleep(4)

        # 6. Matikan seluruh RabbitMQ -> POST tetap 202 (outbox) -> nyalakan -> terkirim
        jalankan(
            ["docker", "stop", "puisi-rabbitmq-1-1", "puisi-rabbitmq-2-1", "puisi-rabbitmq-3-1"],
            check=False,
        )
        kode_post, _, pid6 = kirim_puisi_uji(token, "Skenario 6 (semua RabbitMQ mati)")
        jalankan(
            ["docker", "start", "puisi-rabbitmq-1-1", "puisi-rabbitmq-2-1", "puisi-rabbitmq-3-1"],
            check=False,
        )
        terkirim6 = tunggu_outbox_terkirim(pid6, batas_detik=45)
        catat(
            "Skenario 6: Seluruh RabbitMQ mati -> Outbox -> Pulih & terkirim",
            kode_post == 202 and terkirim6,
            f"POST={kode_post}, outbox_terkirim_setelah_pulih={terkirim6}, id={pid6}",
        )

    finally:
        print("\nMemulihkan seluruh container...")
        jalankan(
            [
                "docker", "start",
                "puisi-poem-service-1",
                "puisi-poem-service-2",
                "puisi-poem-db-router-1-1",
                "puisi-poem-db-router-2-1",
                "puisi-poem-db-1-1",
                "puisi-poem-db-2-1",
                "puisi-poem-db-3-1",
                "puisi-redis-1",
                "puisi-rabbitmq-1-1",
                "puisi-rabbitmq-2-1",
                "puisi-rabbitmq-3-1",
            ],
            check=False,
        )
        jalankan(["docker", "compose", "--profile", "puisi", "start", "poem-db-cluster-init"], check=False)

    gagal = [h for h in hasil_skenario if not h[1]]
    print(f"\nRingkasan Uji Anti-SPOF: {len(hasil_skenario) - len(gagal)}/{len(hasil_skenario)} skenario LULUS.")
    sys.exit(1 if gagal else 0)


if __name__ == "__main__":
    main()

