"""Run the signed installer helper against a temporary Chrome home and app socket."""
import contextlib
import json
import os
from pathlib import Path
import select
import socketserver
import subprocess
import tempfile
import threading
import unittest

from test_host import host


ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'chrome-extension://omkmeoiobbgmdfhjbhbkjmmhcigkogka/'


@unittest.skipUnless(os.uname().sysname == 'Darwin' and os.uname().machine == 'arm64', 'Apple Silicon installer')
class PackagedHostChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        folder = tempfile.TemporaryDirectory(prefix='muse-host-bundle-')
        cls.addClassCleanup(folder.cleanup)
        bundle = Path(folder.name) / 'Muse Guard.app'
        contents = bundle / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes((ROOT / 'Configuration/Info.plist').read_bytes())
        subprocess.run([str(ROOT / 'scripts/bundle-browser.sh'), str(bundle), '-'], check=True, capture_output=True)
        cls.helper = contents / 'Helpers/muse-guard-host'
        cls.extension = contents / 'Resources/ChromeExtension'

    def setUp(self):
        # Keep the Unix socket well under Darwin's 104-byte path limit.
        folder = tempfile.TemporaryDirectory(prefix='mg-', dir='/tmp')
        self.addCleanup(folder.cleanup)
        self.home = Path(folder.name)
        self.env = {**os.environ, 'HOME': str(self.home), 'CFFIXED_USER_HOME': str(self.home)}
        self.endpoint = self.home / 'Library/Application Support/MuseGuard/BrowserBridge/bridge.sock'

    @contextlib.contextmanager
    def app_socket(self, respond):
        self.endpoint.parent.mkdir(parents=True)

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = host.read_frame(self.rfile)
                respond(request, self.rfile, self.wfile)

        with socketserver.ThreadingUnixStreamServer(str(self.endpoint), Handler) as server:
            self.endpoint.chmod(0o600)
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02})
            thread.start()
            try:
                yield
            finally:
                server.shutdown()
                thread.join(timeout=2)

    @contextlib.contextmanager
    def chrome(self):
        with subprocess.Popen([str(self.helper), ORIGIN], env=self.env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0) as process:
            try:
                yield process
            finally:
                if not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                    self.fail('Closing Chrome stdin did not stop the helper promptly.')

    @staticmethod
    def send(process, **request):
        process.stdin.write(host.encode_frame(dict(version=1, mode='text', **request)))

    def receive(self, process):
        self.assertTrue(select.select([process.stdout], [], [], 2)[0], 'No response from the packaged helper.')
        return host.read_frame(process.stdout)

    def test_registration_is_private_exact_and_repeatable(self):
        self.assertEqual(
            {path.name for path in self.extension.iterdir()},
            {'manifest.json', 'background.js', 'content.js', 'downloads.js', 'popup.css', 'popup.html',
             'popup.js', 'secrets.js', 'shared.js', 'targets.js'},
        )
        path = self.home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.antojoseph.museguard.json'
        for _ in range(2):
            subprocess.run([str(self.helper), '--register'], env=self.env, check=True, capture_output=True, timeout=2)
            manifest = json.loads(path.read_text())
            self.assertEqual(manifest['allowed_origins'], [ORIGIN])
            self.assertEqual(Path(manifest['path']).resolve(), self.helper.resolve())
            self.assertEqual(manifest['type'], 'stdio')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        path.unlink()
        protected = self.home / 'do-not-touch'
        protected.write_text('original')
        path.symlink_to(protected)
        denied = subprocess.run([str(self.helper), '--register'], env=self.env, capture_output=True, timeout=2)
        self.assertNotEqual(denied.returncode, 0)
        self.assertEqual(protected.read_text(), 'original')

    def test_exact_origin_and_unavailable_remains_unassessed(self):
        for bad_origin in ['https://example.test', ORIGIN + 'x', 'chrome-extension://' + 'a' * 32 + '/']:
            denied = subprocess.run([str(self.helper), bad_origin], env=self.env, input=b'', capture_output=True, timeout=2)
            self.assertNotEqual(denied.returncode, 0)
            self.assertEqual(denied.stdout, b'')
        reply = subprocess.run([str(self.helper), '--one-shot', ORIGIN.rstrip('/')], env=self.env,
                               input=host.encode_frame({'id': 'offline', 'type': 'status'}),
                               capture_output=True, check=True, timeout=2)
        response = json.loads(reply.stdout[4:])
        self.assertEqual((response['id'], response['ok'], response['risk_level']), ('offline', False, 'unknown'))

    def test_closing_chrome_cancels_socket_without_a_reply(self):
        entered = threading.Event()
        cancelled = threading.Event()

        def respond(request, reader, _):
            if request['id'] == 'cancel':
                entered.set()
                if reader.read(1) == b'':
                    cancelled.set()

        with self.app_socket(respond), self.chrome() as process:
            self.send(process, id='cancel', type='assess')
            self.assertTrue(entered.wait(2))
            process.stdin.close()
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertTrue(cancelled.wait(2))
            self.assertEqual(process.stdout.read(), b'')

    def test_forwards_utf8_and_rejects_an_unrelated_response(self):
        def respond(request, _, writer):
            id = request['id'] if request['id'] == 'unicode' else 'unrelated'
            writer.write(host.encode_frame({'id': id, 'ok': True, 'echo': request.get('text')}))

        with self.app_socket(respond), self.chrome() as process:
            self.send(process, id='unicode', type='assess', text='Café ☕')
            self.assertEqual(self.receive(process), {'id': 'unicode', 'ok': True, 'echo': 'Café ☕'})
            self.send(process, id='expected', type='status')
            reply = self.receive(process)
            self.assertEqual((reply['id'], reply['ok'], reply['decision']), ('expected', False, 'review'))

    def test_saturated_analysis_and_download_lanes_leave_room_for_control(self):
        release = threading.Event()
        reached = {'analysis': threading.Event(), 'download': threading.Event()}
        counts = {'analysis': 0, 'download': 0}
        count_lock = threading.Lock()

        def respond(request, _, writer):
            lane = request['id'].split('-')[0]
            if lane in reached:
                with count_lock:
                    counts[lane] += 1
                    if counts[lane] == {'analysis': host.ANALYSIS_WORKERS, 'download': host.DOWNLOAD_WORKERS}[lane]:
                        reached[lane].set()
                if not release.wait(5):
                    return
            try:
                writer.write(host.encode_frame({'id': request['id'], 'ok': True}))
            except BrokenPipeError:
                pass

        with self.app_socket(respond), self.chrome() as process:
            try:
                for index in range(host.ANALYSIS_CAPACITY + 1):
                    self.send(process, id=f'analysis-{index}', type='assess')
                for index in range(host.DOWNLOAD_CAPACITY + 1):
                    self.send(process, id=f'download-{index}', type='download-inspect', download={'phase': 'complete'})
                self.assertTrue(reached['analysis'].wait(2))
                self.assertTrue(reached['download'].wait(2))
                self.send(process, id='pause', type='monitoring-control')
                self.send(process, id='metadata', type='download-inspect', download={'phase': 'metadata'})
                replies = {reply['id']: reply['ok'] for reply in (self.receive(process) for _ in range(4))}
                self.assertEqual(replies, {
                    f'analysis-{host.ANALYSIS_CAPACITY}': False, f'download-{host.DOWNLOAD_CAPACITY}': False,
                    'pause': True, 'metadata': True,
                })
                self.assertEqual(counts, {'analysis': host.ANALYSIS_WORKERS, 'download': host.DOWNLOAD_WORKERS})
            finally:
                release.set()
