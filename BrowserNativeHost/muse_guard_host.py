#!/usr/bin/env python3
"""Chrome stdio messages <-> the private Muse Guard application socket.

No page content is logged. The model key never passes through this process.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import sys
import threading

MAX_REQUEST = 2_100_000
MAX_RESPONSE = 1_048_576
_ORIGIN = re.compile(r'chrome-extension://[a-p]{32}/?\Z')
# Long file scans and inference may wait for seconds. Metadata, warning
# delivery and Pause must always have their own bounded route to the app.
CONTROL_REQUESTS = frozenset({'status', 'present-block', 'cancel', 'protection-state',
    'chat-context-poll', 'chat-context-result', 'monitoring-state', 'monitoring-control',
    'secret-paste', 'target-update', 'target-invalidated', 'download-command-result'})
ANALYSIS_WORKERS, ANALYSIS_CAPACITY = 4, 8
CONTROL_WORKERS, CONTROL_CAPACITY = 2, 16
DOWNLOAD_WORKERS, DOWNLOAD_CAPACITY = 2, 4


class ProtocolError(Exception):
    pass


def read_exact(stream, count: int, *, clean_eof: bool = False):
    result = bytearray()
    while len(result) < count:
        chunk = stream.read(count-len(result))
        if not chunk:
            if not result and clean_eof:
                return None
            raise ProtocolError('Incomplete native message.')
        result.extend(chunk)
    return bytes(result)


def read_frame(stream, maximum=MAX_REQUEST):
    header = read_exact(stream, 4, clean_eof=True)
    if header is None:
        return None
    size = struct.unpack('<I', header)[0]
    if not 0 < size <= maximum:
        raise ProtocolError('Native message exceeds the local size limit.')
    body = read_exact(stream, size)
    try:
        value = json.loads(body.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError('Native message is not valid JSON.') from error
    if not isinstance(value, dict):
        raise ProtocolError('Native message must be an object.')
    return value


def encode_frame(value, maximum=MAX_RESPONSE):
    body = json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
    if not 0 < len(body) <= maximum:
        raise ProtocolError('Native response exceeds the local size limit.')
    return struct.pack('<I', len(body)) + body


def failure(request, message):
    request_id = request.get('id', '') if isinstance(request, dict) else ''
    if not valid_request_id(request):
        request_id = ''
    return dict(version=1, id=request_id, ok=False, decision='review', risk_level='unknown',
                summary='Muse could not check this action.', guidance=message, categories=[],
                mode='vision' if request.get('mode') == 'vision' else 'text', duration_ms=0, error=message)


def valid_request_id(request):
    value = request.get('id')
    if not isinstance(value, str):
        return False
    try:
        return (0 < len(value.encode('utf-8')) <= 128 and
                not any(ord(character) < 32 or ord(character) == 127 for character in value))
    except UnicodeEncodeError:
        return False


def control_request(request):
    # Framing and UTF-8/object bounds are validated by read_frame first; native
    # Swift validates each complete schema. Unknown/malformed types cannot
    # claim the reserved control lane or crash its membership check.
    kind = request.get('type')
    if request.get('version') != 1 or request.get('mode', 'text') != 'text' or not isinstance(kind, str):
        return False
    if kind == 'download-inspect':
        download = request.get('download')
        return isinstance(download, dict) and download.get('phase') == 'metadata'
    return kind in CONTROL_REQUESTS


def complete_download_request(request):
    download = request.get('download')
    return (request.get('version') == 1 and request.get('mode', 'text') == 'text' and
            request.get('type') == 'download-inspect' and isinstance(download, dict) and
            download.get('phase') == 'complete')


def load_config(path: Path, origin: str):
    if not _ORIGIN.fullmatch(origin):
        raise ProtocolError('Native messaging caller is not an extension origin.')
    attributes = path.lstat()
    if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
        raise ProtocolError('Native bridge configuration must be private to this user.')
    configuration = json.loads(path.read_text())
    if not isinstance(configuration, dict):
        raise ProtocolError('Native bridge configuration must be an object.')
    allowed = configuration.get('allowed_origins')
    if not isinstance(allowed, list) or origin.rstrip('/') + '/' not in allowed:
        raise ProtocolError('This extension is not authorized for Muse Guard.')
    socket_path = configuration.get('socket_path')
    if not isinstance(socket_path, str) or not Path(socket_path).is_absolute() or len(os.fsencode(socket_path)) >= 104:
        raise ProtocolError('Native bridge socket path is not valid.')
    return socket_path


def forward(request, socket_path, active, active_lock, stopping=None):
    if not valid_request_id(request):
        return failure(request, 'The browser request identifier was not valid.')
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(120)
    with active_lock:
        if stopping is not None and stopping.is_set():
            client.close()
            return failure(request, 'The browser connection closed before this check started.')
        active.add(client)
    try:
        # Socket permissions and ownership are checked in addition to the
        # private directory and Chrome's exact extension-origin allow list.
        attributes = Path(socket_path).lstat()
        if not stat.S_ISSOCK(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
            raise ProtocolError('Muse Guard socket is not private to this user.')
        client.connect(socket_path)
        if stopping is not None and stopping.is_set():
            raise ProtocolError('The browser connection closed.')
        client.sendall(encode_frame(request, MAX_REQUEST))
        with client.makefile('rb') as stream:
            response = read_frame(stream, MAX_RESPONSE)
        if not response or response.get('id') != request['id']:
            raise ProtocolError('Muse Guard returned an unrelated response.')
        return response
    except (OSError, ProtocolError, ValueError):
        return failure(request, 'Muse Guard is unavailable. Open the companion app and try again.')
    finally:
        with active_lock:
            active.discard(client)
        client.close()


def run(input_stream, output_stream, socket_path, *, one_shot=False):
    output_lock = threading.Lock()
    active_lock = threading.Lock()
    active = set()
    analysis_slots = threading.BoundedSemaphore(ANALYSIS_CAPACITY)
    control_slots = threading.BoundedSemaphore(CONTROL_CAPACITY)
    download_slots = threading.BoundedSemaphore(DOWNLOAD_CAPACITY)
    analysis_pool = concurrent.futures.ThreadPoolExecutor(max_workers=ANALYSIS_WORKERS, thread_name_prefix='muse-analysis')
    control_pool = concurrent.futures.ThreadPoolExecutor(max_workers=CONTROL_WORKERS, thread_name_prefix='muse-control')
    download_pool = concurrent.futures.ThreadPoolExecutor(max_workers=DOWNLOAD_WORKERS, thread_name_prefix='muse-download')
    stopping = threading.Event()
    clean_eof = False

    def send(response):
        if stopping.is_set():
            return
        try:
            payload = encode_frame(response)
            with output_lock:
                output_stream.write(payload)
                output_stream.flush()
        except (OSError, ValueError, ProtocolError):
            stopping.set()

    def complete(request, slots):
        try:
            send(forward(request, socket_path, active, active_lock, stopping))
        finally:
            slots.release()

    try:
        while not stopping.is_set():
            try:
                request = read_frame(input_stream)
            except ProtocolError:
                # Without a complete request ID, a safe correlated response is
                # impossible. Closing the port makes pending checks unassessed.
                break
            if request is None:
                clean_eof = True
                break
            if not valid_request_id(request):
                send(failure(request, 'The browser request identifier was not valid.'))
                continue
            if control_request(request):
                pool, slots = control_pool, control_slots
            elif complete_download_request(request):
                pool, slots = download_pool, download_slots
            else:
                pool, slots = analysis_pool, analysis_slots
            if slots.acquire(blocking=False):
                pool.submit(complete, request, slots)
            else:
                send(failure(request, 'Muse is busy. Wait for the current check, then retry.'))
    finally:
        drain_final_request = clean_eof and one_shot
        if not drain_final_request:
            stopping.set()
            with active_lock:
                for client in active:
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    client.close()
        # Chrome closing stdin revokes outstanding browser work. Only explicit
        # one-shot diagnostics may await a final reply after their input EOF.
        control_pool.shutdown(wait=True, cancel_futures=not drain_final_request)
        analysis_pool.shutdown(wait=True, cancel_futures=not drain_final_request)
        download_pool.shutdown(wait=True, cancel_futures=not drain_final_request)
        stopping.set()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=Path(__file__).with_name('config.json'))
    parser.add_argument('--one-shot', action='store_true', help='Await the final diagnostic response after stdin EOF.')
    parser.add_argument('origin')
    arguments = parser.parse_args(argv)
    try:
        path = load_config(arguments.config, arguments.origin)
    except (OSError, ValueError, ProtocolError):
        print('Muse Guard rejected the native host configuration or caller.', file=sys.stderr)
        return 1
    run(sys.stdin.buffer, sys.stdout.buffer, path, one_shot=arguments.one_shot)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
