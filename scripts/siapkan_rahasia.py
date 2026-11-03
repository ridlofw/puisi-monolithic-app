"""Buat secrets/jwt_secret.txt sekali per mesin. Berkas itu tidak pernah di-commit."""
import os
import secrets

AKAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(AKAR, 'secrets', 'jwt_secret.txt')

if os.path.exists(PATH):
    print('sudah ada, tidak diubah: secrets/jwt_secret.txt')
else:
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    with open(PATH, 'w', encoding='utf-8') as f:
        f.write(secrets.token_urlsafe(48))
    print('dibuat: secrets/jwt_secret.txt')
