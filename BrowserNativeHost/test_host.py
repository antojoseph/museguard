#!/usr/bin/env python3
"""Stdlib-only protocol and concurrent native transport checks; no Chrome data."""
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest

_SPEC = importlib.util.spec_from_file_location('muse_guard_host', Path(__file__).with_name('muse_guard_host.py'))
host = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(host)


class HostChecks(unittest.TestCase):
    def test_frames_are_utf8_and_bounded(self):
        value = {'id': 'unicode', 'text': 'Café ☕'}
        framed = host.encode_frame(value)
        self.assertEqual(struct.unpack('<I', framed[:4])[0], len(framed)-4)
        self.assertEqual(host.read_frame(io.BytesIO(framed)), value)
        self.assertIsNone(host.read_frame(io.BytesIO()))
        for malformed in [b'\x01', struct.pack('<I', 10)+b'{}', struct.pack('<I', host.MAX_REQUEST+1), struct.pack('<I', 2)+b'[]', struct.pack('<I', 1)+b'\xff']:
            with self.assertRaises(host.ProtocolError):
                host.read_frame(io.BytesIO(malformed))
        with self.assertRaises(host.ProtocolError):
            host.encode_frame({'text': 'x'*100}, 10)

    def test_exact_origin_and_private_configuration(self):
        with tempfile.TemporaryDirectory(prefix='muse-native-check-', dir='/tmp') as folder:
            config = Path(folder)/'config.json'
            origin = 'chrome-extension://'+'a'*32+'/'
            config.write_text(json.dumps({'allowed_origins': [origin], 'socket_path': str(Path(folder)/'bridge.sock')}))
            config.chmod(0o600)
            self.assertEqual(host.load_config(config, origin.rstrip('/')), str(Path(folder)/'bridge.sock'))
            for invalid in ['https://example.test', 'chrome-extension://'+'b'*32+'/', origin+'extra', origin+'?query=1']:
                with self.assertRaises(host.ProtocolError):
                    host.load_config(config, invalid)
            config.chmod(0o644)
            with self.assertRaises(host.ProtocolError):
                host.load_config(config, origin)

    def test_unavailable_is_review_not_safe(self):
        result = host.forward({'id': 'unavailable', 'mode': 'text'}, '/tmp/muse-missing-test.sock', set(), threading.Lock())
        self.assertEqual((result['id'], result['ok'], result['decision'], result['risk_level']), ('unavailable', False, 'review', 'unknown'))

    def test_configuration_rejects_non_object_json(self):
        with tempfile.TemporaryDirectory(prefix='muse-native-check-', dir='/tmp') as folder:
            config = Path(folder)/'config.json'
            origin = 'chrome-extension://'+'a'*32+'/'
            for value in [[], None, 'invalid', 1]:
                config.write_text(json.dumps(value))
                config.chmod(0o600)
                with self.assertRaises(host.ProtocolError):
                    host.load_config(config, origin)

    def test_concurrent_requests_keep_their_ids(self):
        with tempfile.TemporaryDirectory(prefix='muse-native-check-', dir='/tmp') as folder:
            endpoint = str(Path(folder)/'bridge.sock')
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(endpoint); os.chmod(endpoint, 0o600); server.listen(4)
            connections = []
            def answer(client):
                with client, client.makefile('rb') as reader:
                    request = host.read_frame(reader)
                    if request['id'] == 'slow':
                        time.sleep(.2)
                    client.sendall(host.encode_frame(dict(id=request['id'], ok=True, decision='allow')))
            def accept_two():
                for _ in range(2):
                    client, _ = server.accept()
                    thread = threading.Thread(target=answer, args=(client,))
                    connections.append(thread); thread.start()
            accepting = threading.Thread(target=accept_two); accepting.start()
            input_read, input_write = os.pipe()
            output_read, output_write = os.pipe()
            with os.fdopen(input_read, 'rb', buffering=0) as native_input, os.fdopen(output_write, 'wb', buffering=0) as native_output:
                running = threading.Thread(target=host.run, args=(native_input, native_output, endpoint))
                running.start()
                with os.fdopen(input_write, 'wb', buffering=0) as chrome_output, os.fdopen(output_read, 'rb', buffering=0) as chrome_input:
                    chrome_output.write(host.encode_frame(dict(id='slow'))+host.encode_frame(dict(id='fast')))
                    responses = [host.read_frame(chrome_input), host.read_frame(chrome_input)]
                    self.assertEqual([response['id'] for response in responses], ['fast', 'slow'])
                running.join(timeout=2)
                self.assertFalse(running.is_alive())
            accepting.join(timeout=2)
            for thread in connections:
                thread.join(timeout=2)
            server.close()

    def test_browser_eof_closes_pending_application_connection(self):
        with tempfile.TemporaryDirectory(prefix='muse-native-check-', dir='/tmp') as folder:
            endpoint = str(Path(folder)/'bridge.sock')
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(endpoint); os.chmod(endpoint, 0o600); server.listen(1); server.settimeout(2)
            entered, disconnected = threading.Event(), threading.Event()
            def application():
                client, _ = server.accept()
                with client, client.makefile('rb') as reader:
                    self.assertEqual(host.read_frame(reader)['id'], 'cancel-on-eof')
                    entered.set()
                    if reader.read(1) == b'':
                        disconnected.set()
            accepting = threading.Thread(target=application); accepting.start()
            input_read, input_write = os.pipe()
            output = io.BytesIO()
            with os.fdopen(input_read, 'rb', buffering=0) as native_input:
                running = threading.Thread(target=host.run, args=(native_input, output, endpoint)); running.start()
                with os.fdopen(input_write, 'wb', buffering=0) as chrome_output:
                    chrome_output.write(host.encode_frame(dict(id='cancel-on-eof')))
                    self.assertTrue(entered.wait(1))
                running.join(timeout=1)
                self.assertFalse(running.is_alive(), 'Chrome disconnect must not wait for the old model request.')
                self.assertTrue(disconnected.wait(1))
                self.assertEqual(output.getvalue(), b'')
            accepting.join(timeout=1); server.close()

    def test_explicit_one_shot_may_receive_final_reply_after_input_eof(self):
        with tempfile.TemporaryDirectory(prefix='muse-native-check-', dir='/tmp') as folder:
            endpoint = str(Path(folder)/'bridge.sock')
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(endpoint); os.chmod(endpoint, 0o600); server.listen(1); server.settimeout(2)
            def application():
                client, _ = server.accept()
                with client, client.makefile('rb') as reader:
                    request = host.read_frame(reader)
                    time.sleep(.05)
                    client.sendall(host.encode_frame(dict(id=request['id'], ok=True, decision='review')))
            accepting = threading.Thread(target=application); accepting.start()
            output = io.BytesIO()
            host.run(io.BytesIO(host.encode_frame(dict(id='one-shot'))), output, endpoint, one_shot=True)
            self.assertEqual(host.read_frame(io.BytesIO(output.getvalue()))['id'], 'one-shot')
            accepting.join(timeout=1); server.close()


if __name__ == '__main__':
    unittest.main()
