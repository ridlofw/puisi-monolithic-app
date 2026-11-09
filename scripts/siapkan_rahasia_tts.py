"""Generate local-only credentials for the TTS database and S3 adapter."""
import json
import os
import secrets

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_DIR = os.path.join(ROOT, "secrets")
NAMES = {
    "tts_db_root_password.txt": secrets.token_urlsafe(36),
    "tts_db_password.txt": secrets.token_urlsafe(36),
    "s3_access_key.txt": secrets.token_hex(16),
    "s3_secret_key.txt": secrets.token_urlsafe(40),
    "s3_init_access_key.txt": secrets.token_hex(16),
    "s3_init_secret_key.txt": secrets.token_urlsafe(40),
}


def main():
    os.makedirs(SECRET_DIR, exist_ok=True)
    paths = [os.path.join(SECRET_DIR, name) for name in NAMES]
    config_path = os.path.join(SECRET_DIR, "seaweedfs_s3.json")
    for name, value in NAMES.items():
        if not os.path.exists(os.path.join(SECRET_DIR, name)):
            with open(os.path.join(SECRET_DIR, name), "w", encoding="utf-8") as stream:
                stream.write(value)
    for name in NAMES:
        with open(os.path.join(SECRET_DIR, name), encoding="utf-8") as stream:
            NAMES[name] = stream.read().strip()
    config = {
        "identities": [
            {"name": "tts-worker", "credentials": [{
                "accessKey": NAMES["s3_access_key.txt"],
                "secretKey": NAMES["s3_secret_key.txt"],
            }], "actions": ["Read:audio", "Write:audio", "List:audio"]},
            {"name": "tts-bucket-init", "credentials": [{
                "accessKey": NAMES["s3_init_access_key.txt"],
                "secretKey": NAMES["s3_init_secret_key.txt"],
            }], "actions": ["Admin:audio"]},
            {"name": "anonymous", "actions": ["Read:audio"]},
        ]
    }
    with open(config_path, "w", encoding="utf-8") as stream:
        json.dump(config, stream, indent=2)
        stream.write("\n")
    try:
        os.chmod(SECRET_DIR, 0o700)
        for path in paths + [config_path]:
            os.chmod(path, 0o600)
    except OSError:
        # Windows ACLs govern local access; Docker Desktop mounts the files read-only.
        pass
    print("TTS local secrets are ready under secrets/. Credential values were not displayed.")


if __name__ == "__main__":
    main()
