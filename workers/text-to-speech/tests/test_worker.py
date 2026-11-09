import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
for parent in Path(__file__).resolve().parents:
    template = parent / "_templat"
    if template.is_dir():
        sys.path.insert(0, str(template))
        break

import amplop
import worker
from suara import SynthesisError, SynthesisResult


class FakeStore:
    def __init__(self, state="claimed", attempt=1, fail_complete=False):
        self.state = state
        self.attempt = attempt
        self.completed = []
        self.failures = []
        self.fail_complete = fail_complete
        self.pending = []
        self.published = []

    def claim(self, puisi_id):
        if self.state == "claimed":
            return {"state": "claimed", "attempt": self.attempt, "token": "lease-test"}
        return {"state": self.state, "attempt": self.attempt}

    def complete(self, *args):
        if self.fail_complete:
            raise RuntimeError("database commit unavailable")
        self.completed.append(args)

    def fail(self, *args):
        self.failures.append(args)

    def pending_events(self):
        return self.pending

    def mark_published(self, row_id):
        self.published.append(row_id)


class FakeChannel:
    def __init__(self):
        self.acks = []
        self.rejects = []
        self.nacks = []
        self.publishes = []
        self.publish_result = True

    def confirm_delivery(self):
        pass

    def basic_ack(self, delivery_tag):
        self.acks.append(delivery_tag)

    def basic_reject(self, delivery_tag, requeue):
        self.rejects.append((delivery_tag, requeue))

    def basic_nack(self, delivery_tag, requeue):
        self.nacks.append((delivery_tag, requeue))

    def basic_publish(self, **kwargs):
        self.publishes.append(kwargs)
        return self.publish_result


class FakeConnection:
    def __init__(self, channel):
        self._channel = channel
        self.closed = False

    def channel(self):
        return self._channel

    def close(self):
        self.closed = True


class FakeS3:
    def __init__(self):
        self.uploads = []

    def put_object(self, **kwargs):
        self.uploads.append(kwargs)


def message():
    event = amplop.buat("puisi.dibuat", {"puisi_id": 41, "isi": "Pagi yang cerah"}, "corr-41")
    return amplop.ke_bytes(event)


class TestConsumer(unittest.TestCase):
    def setUp(self):
        self.channel = FakeChannel()
        self.props = SimpleNamespace(headers={}, content_type="application/json", message_id="evt-41",
                                     correlation_id="corr-41", type="puisi.dibuat")
        self.method = SimpleNamespace(delivery_tag=7)

    def test_success_uploads_then_persists_outbox_and_acks(self):
        store, s3 = FakeStore(), FakeS3()

        def synthesize(_poem, output):
            Path(output).write_bytes(b"mp3-bytes")
            return SynthesisResult(Path(output), 2.5, 0.4)

        with patch.object(worker, "synthesize_poem", side_effect=synthesize):
            worker.process_message(self.channel, self.method, self.props, message(), store, s3, worker.Metrik("test", worker.QUEUE))
        self.assertEqual(self.channel.acks, [7])
        self.assertEqual(len(s3.uploads), 1)
        self.assertEqual(s3.uploads[0]["Key"], "puisi_41.mp3")
        self.assertEqual(len(store.completed), 1)
        self.assertEqual(store.completed[0][0:3], (41, "lease-test", "puisi_41.mp3"))
        self.assertEqual(store.completed[0][3], 2.5)
        self.assertEqual(store.completed[0][4]["data"]["url_audio"], "/audio/puisi_41.mp3")

    def test_duplicate_completed_job_is_acked_without_reprocessing(self):
        store, s3 = FakeStore(state="selesai"), FakeS3()
        with patch.object(worker, "synthesize_poem") as synthesize:
            worker.process_message(self.channel, self.method, self.props, message(), store, s3, worker.Metrik("test", worker.QUEUE))
        synthesize.assert_not_called()
        self.assertEqual(self.channel.acks, [7])
        self.assertEqual(s3.uploads, [])

    def test_transient_failure_persists_attempt_then_confirm_republishes(self):
        store, s3 = FakeStore(), FakeS3()
        with patch.object(worker, "synthesize_poem", side_effect=SynthesisError("temporary engine error")), patch.object(worker.time, "sleep"):
            worker.process_message(self.channel, self.method, self.props, message(), store, s3, worker.Metrik("test", worker.QUEUE))
        self.assertEqual(len(store.failures), 1)
        self.assertEqual(store.failures[0][1:4], ("lease-test", 1, unittest.mock.ANY))
        self.assertFalse(store.failures[0][4])
        self.assertEqual(self.channel.publishes[0]["properties"].headers["x-percobaan"], 2)
        self.assertEqual(self.channel.acks, [7])

    def test_upload_then_database_failure_retries_with_same_object_key(self):
        store, s3 = FakeStore(fail_complete=True), FakeS3()

        def synthesize(_poem, output):
            Path(output).write_bytes(b"mp3-bytes")
            return SynthesisResult(Path(output), 2.5, 0.4)

        with patch.object(worker, "synthesize_poem", side_effect=synthesize), patch.object(worker.time, "sleep"):
            worker.process_message(self.channel, self.method, self.props, message(), store, s3, worker.Metrik("test", worker.QUEUE))
        self.assertEqual([upload["Key"] for upload in s3.uploads], ["puisi_41.mp3"])
        self.assertEqual(store.completed, [])
        self.assertTrue(store.failures)
        self.assertEqual(self.channel.publishes[0]["properties"].headers["x-percobaan"], 2)
        self.assertEqual(self.channel.acks, [7])

    def test_malformed_event_is_rejected_to_dlq(self):
        store, s3 = FakeStore(), FakeS3()
        worker.process_message(self.channel, self.method, self.props, b"{bad", store, s3, worker.Metrik("test", worker.QUEUE))
        self.assertEqual(self.channel.rejects, [(7, False)])
        self.assertEqual(self.channel.acks, [])

    def test_persisted_failed_job_is_rejected_to_dlq(self):
        store, s3 = FakeStore(state="gagal"), FakeS3()
        worker.process_message(self.channel, self.method, self.props, message(), store, s3, worker.Metrik("test", worker.QUEUE))
        self.assertEqual(self.channel.rejects, [(7, False)])

    def test_outbox_marks_only_after_confirmed_publish(self):
        store = FakeStore()
        store.pending = [{"id": 12, "event_id": "event-12", "routing_key": "audio.siap",
                          "body": b'{"event_id":"event-12"}'}]
        channel = FakeChannel()
        connection = FakeConnection(channel)
        with patch.object(worker, "connect_amqp", return_value=(connection, "rabbitmq-1")):
            worker.publish_outbox(store, ["amqp://unused"], once=True)
        self.assertEqual(store.published, [12])
        self.assertTrue(connection.closed)

    def test_outbox_keeps_record_when_publish_is_not_confirmed(self):
        store = FakeStore()
        store.pending = [{"id": 13, "event_id": "event-13", "routing_key": "audio.siap",
                          "body": b'{"event_id":"event-13"}'}]
        channel = FakeChannel()
        channel.publish_result = False
        connection = FakeConnection(channel)
        with patch.object(worker, "connect_amqp", return_value=(connection, "rabbitmq-1")):
            worker.publish_outbox(store, ["amqp://unused"], once=True)
        self.assertEqual(store.published, [])
        self.assertTrue(connection.closed)


if __name__ == "__main__":
    unittest.main()
