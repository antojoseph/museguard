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
from unittest.mock import patch

_SPEC = importlib.util.spec_from_file_location('muse_guard_host', Path(__file__).with_name('muse_guard_host.py'))
host = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(host)


class HostChecks(unittest.TestCase):
    @staticmethod
    def wait_until(predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() >= deadline:
                return False
            time.sleep(.005)
        return True

    @staticmethod
    def responses(output):
        snapshot = io.BytesIO(output.getvalue())
        result = []
        while True:
            value = host.read_frame(snapshot)
            if value is None:
                return result
            result.append(value)

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

    def test_saturated_analyses_cannot_delay_pause_or_secret_warning_delivery(self):
        release = threading.Event()
        lock = threading.Lock()
        started = []
        output = io.BytesIO()

        def forward(request, *_):
            with lock:
                started.append(request['id'])
            if request.get('type') == 'assess':
                release.wait(3)
            return dict(id=request['id'], ok=True, decision='review')

        input_read, input_write = os.pipe()
        with patch.object(host, 'forward', side_effect=forward), os.fdopen(input_read, 'rb', buffering=0) as native_input:
            running = threading.Thread(target=host.run, args=(native_input, output, '/tmp/unused.sock'))
            running.start()
            try:
                with os.fdopen(input_write, 'wb', buffering=0) as chrome_output:
                    for index in range(host.ANALYSIS_CAPACITY):
                        chrome_output.write(host.encode_frame(dict(version=1, id=f'analysis-{index}', type='assess')))
                    self.assertTrue(self.wait_until(lambda: len(started) == host.ANALYSIS_WORKERS))
                    chrome_output.write(host.encode_frame(dict(version=1, id='overflow', type='assess')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='pause-now', type='monitoring-control')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='secret-now', type='secret-paste')))
                    self.assertTrue(self.wait_until(lambda: {'pause-now', 'secret-now'}.issubset({item['id'] for item in self.responses(output)})),
                                    'Control messages must reach the app while all analysis workers are blocked.')
                    responses = {item['id']: item for item in self.responses(output)}
                    self.assertFalse(responses['overflow']['ok'])
                    self.assertEqual(sum(item.startswith('analysis-') for item in started), host.ANALYSIS_WORKERS)
                    self.assertNotIn('overflow', started)
                    release.set()
            finally:
                release.set()
                running.join(timeout=2)
                self.assertFalse(running.is_alive())

    def test_control_lane_has_its_own_bound_and_invalid_ids_never_reserve_slots(self):
        release = threading.Event()
        started = []
        output = io.BytesIO()

        def forward(request, *_):
            started.append(request['id'])
            if request.get('type') == 'monitoring-state':
                release.wait(3)
            return dict(id=request['id'], ok=True, decision='review')

        input_read, input_write = os.pipe()
        with patch.object(host, 'forward', side_effect=forward), os.fdopen(input_read, 'rb', buffering=0) as native_input:
            running = threading.Thread(target=host.run, args=(native_input, output, '/tmp/unused.sock'))
            running.start()
            try:
                with os.fdopen(input_write, 'wb', buffering=0) as chrome_output:
                    chrome_output.write(host.encode_frame(dict(version=1, id='bad\nidentifier', type='monitoring-state')))
                    for index in range(host.CONTROL_CAPACITY):
                        chrome_output.write(host.encode_frame(dict(version=1, id=f'control-{index}', type='monitoring-state')))
                    self.assertTrue(self.wait_until(lambda: len(started) == host.CONTROL_WORKERS))
                    chrome_output.write(host.encode_frame(dict(version=1, id='control-overflow', type='monitoring-state')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='analysis-now', type='assess')))
                    self.assertTrue(self.wait_until(lambda: 'analysis-now' in {item['id'] for item in self.responses(output)}))
                    responses = {item['id']: item for item in self.responses(output)}
                    self.assertFalse(responses['']['ok'])
                    self.assertFalse(responses['control-overflow']['ok'])
                    self.assertNotIn('bad\nidentifier', started)
                    self.assertNotIn('control-overflow', started)
                    self.assertEqual(sum(item.startswith('control-') for item in started), host.CONTROL_WORKERS)
                    release.set()
            finally:
                release.set()
                running.join(timeout=2)
                self.assertFalse(running.is_alive())

    def test_reserved_lane_uses_exact_type_and_valid_id(self):
        for kind in host.CONTROL_REQUESTS:
            self.assertTrue(host.control_request(dict(version=1, type=kind)))
        for request in [dict(version=1, type={}), dict(version=1, type='download-inspect'),
                        dict(version=1, type='assess'), dict(version=2, type='secret-paste'),
                        dict(version=1, type='secret-paste', mode='vision')]:
            self.assertFalse(host.control_request(request))
        for value in ['', 'x'*129, 'line\nfeed', '\ud800', None, {}]:
            self.assertFalse(host.valid_request_id(dict(id=value)))
        self.assertTrue(host.valid_request_id(dict(id='safe-identifier')))

    def test_complete_download_lane_cannot_delay_new_analysis_metadata_or_monitoring(self):
        release = threading.Event()
        started = []
        output = io.BytesIO()

        def forward(request, *_):
            started.append(request['id'])
            if host.complete_download_request(request):
                release.wait(3)
            return dict(id=request['id'], ok=True, decision='review')

        input_read, input_write = os.pipe()
        with patch.object(host, 'forward', side_effect=forward), os.fdopen(input_read, 'rb', buffering=0) as native_input:
            running = threading.Thread(target=host.run, args=(native_input, output, '/tmp/unused.sock'))
            running.start()
            try:
                with os.fdopen(input_write, 'wb', buffering=0) as chrome_output:
                    for index in range(host.DOWNLOAD_CAPACITY):
                        chrome_output.write(host.encode_frame(dict(version=1, id=f'download-{index}', type='download-inspect', download=dict(phase='complete'))))
                    self.assertTrue(self.wait_until(lambda: len(started) == host.DOWNLOAD_WORKERS))
                    chrome_output.write(host.encode_frame(dict(version=1, id='download-overflow', type='download-inspect', download=dict(phase='complete'))))
                    chrome_output.write(host.encode_frame(dict(version=1, id='analysis-now', type='assess')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='metadata-now', type='download-inspect', download=dict(phase='metadata'))))
                    chrome_output.write(host.encode_frame(dict(version=1, id='monitoring-now', type='monitoring-state')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='pause-now', type='monitoring-control')))
                    chrome_output.write(host.encode_frame(dict(version=1, id='secret-now', type='secret-paste')))
                    expected = {'analysis-now', 'metadata-now', 'monitoring-now', 'pause-now', 'secret-now'}
                    self.assertTrue(self.wait_until(lambda: expected.issubset({item['id'] for item in self.responses(output)})),
                                    'File scans must not occupy analysis or short control workers.')
                    responses = {item['id']: item for item in self.responses(output)}
                    self.assertFalse(responses['download-overflow']['ok'])
                    self.assertNotIn('download-overflow', started)
                    self.assertEqual(sum(item.startswith('download-') for item in started), host.DOWNLOAD_WORKERS)
                    release.set()
            finally:
                release.set()
                running.join(timeout=2)
                self.assertFalse(running.is_alive())

    def test_download_lane_classification_requires_exact_phase(self):
        self.assertTrue(host.control_request(dict(version=1, type='download-inspect', download=dict(phase='metadata'))))
        self.assertTrue(host.complete_download_request(dict(version=1, type='download-inspect', download=dict(phase='complete'))))
        for download in [None, [], {}, dict(phase='metadata '), dict(phase='complete '), dict(phase='invalid'), dict(phase={})]:
            request = dict(version=1, type='download-inspect', download=download)
            self.assertFalse(host.control_request(request))
            self.assertFalse(host.complete_download_request(request))


if __name__ == '__main__':
    unittest.main()
