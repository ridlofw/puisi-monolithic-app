"""Amplop event bersama. Bentuknya ditetapkan di kontrak/README.md."""
import json
import uuid
from datetime import datetime, timezone

VERSI = 1
WAJIB = ('event_id', 'tipe', 'versi', 'terjadi_pada', 'correlation_id', 'data')


class AmplopTidakSah(ValueError):
    pass


def buat(tipe, data, correlation_id):
    return {
        'event_id': str(uuid.uuid4()),
        'tipe': tipe,
        'versi': VERSI,
        'terjadi_pada': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'correlation_id': correlation_id or str(uuid.uuid4()),
        'data': data,
    }


def baca(body):
    try:
        event = json.loads(body)
    except (TypeError, ValueError) as e:
        raise AmplopTidakSah('body bukan JSON: %s' % e)
    if not isinstance(event, dict):
        raise AmplopTidakSah('body bukan objek JSON')
    kurang = [k for k in WAJIB if k not in event]
    if kurang:
        raise AmplopTidakSah('field amplop tidak ada: %s' % ', '.join(kurang))
    if not isinstance(event['data'], dict):
        raise AmplopTidakSah('data harus objek JSON')
    return event


def ke_bytes(event):
    return json.dumps(event, ensure_ascii=False).encode('utf-8')
