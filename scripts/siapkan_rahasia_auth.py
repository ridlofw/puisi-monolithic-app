"""Create local auth database secrets without overwriting existing values."""
import os
import secrets

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_DIR = os.path.join(ROOT, 'secrets')


def main():
    os.makedirs(SECRET_DIR, exist_ok=True)
    for name in ('auth_db_password.txt', 'auth_db_root_password.txt'):
        path = os.path.join(SECRET_DIR, name)
        if os.path.exists(path):
            print(f'already exists, unchanged: secrets/{name}')
            continue
        with open(path, 'w', encoding='utf-8') as secret_file:
            secret_file.write(secrets.token_urlsafe(36))
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        print(f'created: secrets/{name}')


if __name__ == '__main__':
    main()
