#!/usr/bin/env python3
"""Chrome stdio messages <-> the private Muse Guard application socket.

No page content is logged. The model key never passes through this process.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import io
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
    if not isinstance(request_id, str) or len(request_id.encode('utf-8')) > 128:
        request_id = ''
    return dict(version=1, id=request_id, ok=False, decision='review', risk_level='unknown',
                summary='Muse could not check this action.', guidance=message, categories=[],
                mode='vision' if request.get('mode') == 'vision' else 'text', duration_ms=0, error=message)


def load_config(path: Path, origin: str):
    if not _ORIGIN.fullmatch(origin):
        raise ProtocolError('Native messaging caller is not an extension origin.')
    attributes = path.lstat()
    if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
        raise ProtocolError('Native bridge configuration must be private to this user.')
    configuration = json.loads(path.read_text())
    allowed = configuration.get('allowed_origins')
    if not isinstance(allowed, list) or origin.rstrip('/') + '/' not in allowed:
        raise ProtocolError('This extension is not authorized for Muse Guard.')
    socket_path = configuration.get('socket_path')
    if not isinstance(socket_path, str) or not Path(socket_path).is_absolute() or len(os.fsencode(socket_path)) >= 104:
        raise ProtocolError('Native bridge socket path is not valid.')
    return socket_path


def forward(request, socket_path, active, active_lock):
    if not isinstance(request.get('id'), str) or not 0 < len(request['id'].encode('utf-8')) <= 128:
        return failure(request, 'The browser request identifier was not valid.')
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(120)
    with active_lock:
        active.add(client)
    try:
        # Socket permissions and ownership are checked in addition to the
        # private directory and Chrome's exact extension-origin allow list.
        attributes = Path(socket_path).lstat()
        if not stat.S_ISSOCK(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
            raise ProtocolError('Muse Guard socket is not private to this user.')
        client.connect(socket_path)
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


def run(input_stream, output_stream, socket_path):
    output_lock = threading.Lock()
    active_lock = threading.Lock()
    active = set()
    slots = threading.BoundedSemaphore(8)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix='muse-native')
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

    def complete(request):
        try:
            send(forward(request, socket_path, active, active_lock))
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
            if slots.acquire(blocking=False):
                pool.submit(complete, request)
            else:
                send(failure(request, 'Muse is busy. Wait for the current check, then retry.'))
    finally:
        if not clean_eof:
            stopping.set()
            with active_lock:
                for client in active:
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        # A complete final message can still be answered after stdin EOF. This
        # also makes the host usable by native-message smoke-test harnesses.
        pool.shutdown(wait=True, cancel_futures=not clean_eof)
        stopping.set()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=Path(__file__).with_name('config.json'))
    parser.add_argument('origin')
    arguments = parser.parse_args(argv)
    try:
        path = load_config(arguments.config, arguments.origin)
    except (OSError, ValueError, ProtocolError):
        print('Muse Guard rejected the native host configuration or caller.', file=sys.stderr)
        return 1
    run(sys.stdin.buffer, sys.stdout.buffer, path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
