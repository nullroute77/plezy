#!/usr/bin/env python3
"""Decode identifiable EVENT HLS frames using the actual pinned libmpv.

Run on the library's operating system/architecture. Requires FFmpeg with libx264.
No real server or application installation is used. A temporary HTTP fixture
reveals pre-generated test segments; this is not a production recording/proxy.
Example: python retained_hls.py --libmpv libmpv-2.dll --ffmpeg ffmpeg --pause-seconds 65
"""
import argparse
import ctypes as c
import http.server
import json
import math
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class NativePlayer:
    class Event(c.Structure):
        _fields_ = [('id', c.c_int), ('error', c.c_int),
                    ('reply', c.c_uint64), ('data', c.c_void_p)]

    def __init__(self, library):
        self.lib = c.CDLL(str(Path(library).resolve()))
        self.create = self.bind('mpv_create', [], c.c_void_p)
        self.init = self.bind('mpv_initialize', [c.c_void_p], c.c_int)
        self.option = self.bind('mpv_set_option_string', [c.c_void_p, c.c_char_p, c.c_char_p], c.c_int)
        self.property = self.bind('mpv_get_property_string', [c.c_void_p, c.c_char_p], c.c_void_p)
        self.free = self.bind('mpv_free', [c.c_void_p], None)
        self.command = self.bind('mpv_command', [c.c_void_p, c.POINTER(c.c_char_p)], c.c_int)
        self.wait = self.bind('mpv_wait_event', [c.c_void_p, c.c_double], c.POINTER(self.Event))
        self.destroy = self.bind('mpv_terminate_destroy', [c.c_void_p], None)
        self.handle = self.create()
        if not self.handle:
            raise RuntimeError('mpv_create failed')
        for name, value in {'config': 'no', 'vo': 'null', 'ao': 'null', 'pause': 'yes',
                            'idle': 'yes', 'cache': 'no', 'demuxer-max-bytes': '32768',
                            'demuxer-max-back-bytes': '0', 'demuxer-readahead-secs': '0',
                            'screenshot-format': 'png',
                            'http-header-fields': 'User-Agent: Plezy-Live-HLS/1'}.items():
            self.check(self.option(self.handle, name.encode(), value.encode()))
        self.check(self.init(self.handle))

    def bind(self, name, arguments, result):
        function = getattr(self.lib, name)
        function.argtypes, function.restype = arguments, result
        return function

    @staticmethod
    def check(code):
        if code < 0:
            raise RuntimeError(f'mpv error {code}')

    def get(self, name):
        pointer = self.property(self.handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode()
        finally:
            self.free(pointer)

    def send(self, *arguments):
        encoded = [str(arg).encode() for arg in arguments] + [None]
        self.check(self.command(self.handle, (c.c_char_p * len(encoded))(*encoded)))

    def drain(self):
        while self.wait(self.handle, 0).contents.id:
            pass

    def ready(self):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.wait(self.handle, 0.05).contents.id == 21:
                return
        raise AssertionError('No decoded frame before timeout')

    def close(self):
        self.destroy(self.handle)


def run_case(args, root, container):
    root.mkdir()
    suffix = 'ts' if container == 'ts' else 'm4s'
    playlist = root / 'all.m3u8'
    command = [args.ffmpeg, '-y', '-v', 'error', '-f', 'lavfi', '-i',
               "nullsrc=s=160x96:r=25,geq=lum='32+floor(T)*3':cb=128:cr=128",
               '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
               '-t', '60', '-c:a', 'aac', '-b:a', '64k', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '25',
               '-bf', '2', '-pix_fmt', 'yuv420p', '-f', 'hls', '-hls_time', '1.3',
               '-hls_list_size', '0', '-hls_playlist_type', 'event',
               '-hls_segment_filename', str(root / ('%03d.' + suffix))]
    if container == 'fmp4':
        command += ['-hls_segment_type', 'fmp4', '-hls_fmp4_init_filename', 'init.mp4']
    subprocess.run(command + [str(playlist)], check=True, cwd=root)
    lines = playlist.read_text().splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith('#EXTINF'))
    prefix = lines[:first]
    # An explicit negative START must not override the stable demux origin.
    prefix += ['#EXT-X-START:TIME-OFFSET=-3']
    segments = [lines[i:i + 2] for i, line in enumerate(lines) if line.startswith('#EXTINF')]
    durations = [float(segment[0].split(':')[1].split(',')[0]) for segment in segments]
    state = {'visible': 23, 'requests': [], 'userAgents': set()}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            state['requests'].append(self.path)
            state['userAgents'].add(self.headers.get('User-Agent'))
            if self.path == '/live.m3u8':
                data = ('\n'.join(prefix + sum(segments[:state['visible']], [])) + '\n').encode()
            else:
                file = root / self.path.lstrip('/')
                if not file.is_file():
                    self.send_error(404)
                    return
                data = file.read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *unused):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/live.m3u8'
    player = NativePlayer(args.libmpv)
    print(json.dumps({'container': container, 'mpv': player.get('mpv-version'),
                      'ffmpeg': player.get('ffmpeg-version')}), flush=True)

    def verify(label, target, reopen=True):
        player.drain()
        before = len(state['requests'])
        if reopen:
            player.send('loadfile', url, 'replace', '-1',
                        f'demuxer-lavf-o-append=live_start_index=0,demuxer-lavf-o-add=prefer_x_start=0,start={target}')
        else:
            player.send('seek', target, 'absolute+exact')
        player.ready()
        position = float(player.get('time-pos'))
        assert player.get('pause') == 'yes', label
        screenshot = root / f'{label}.png'
        player.send('screenshot-to-file', screenshot, 'video')
        pixels = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(screenshot),
                                          '-f', 'rawvideo', '-pix_fmt', 'gray', '-'])
        source_second = round((pixels[len(pixels) // 2] * 219 / 255 + 16 - 32) / 3)
        assert abs(position - target) < 0.15, (label, position, target, source_second, player.get('video-pts'))
        assert math.floor(target - 0.15) <= source_second <= math.floor(target + 0.15), (label, source_second, target)
        fetched = state['requests'][before:]
        elapsed = 0
        expected_segment = None
        for segment, duration in zip(segments, durations):
            if elapsed + duration > target:
                expected_segment = '/' + segment[1]
                break
            elapsed += duration
        assert expected_segment in fetched, (label, expected_segment, fetched)
        assert state['userAgents'] == {'Plezy-Live-HLS/1'}, state['userAgents']
        cache = json.loads(player.get('demuxer-cache-state'))
        assert not cache['seekable-ranges'], cache
        row = {'case': label, 'container': container, 'requested': target, 'position': position,
               'decodedSourceSecond': source_second, 'paused': True, 'fetch': fetched,
               'userAgent': next(iter(state['userAgents'])),
               'localSeekableRanges': cache['seekable-ranges'], 'origin': player.get('demuxer-start-time')}
        print(json.dumps(row), flush=True)
        return row

    try:
        original = verify('deep-join', 20)
        verify('rewind-outside-cache', 3, reopen=False)
        verify('forward', 22)
        verify('rewind-paused', 4)
        # Manual seeking can enter the live hold-back, but never exact EOF.
        # Keep the playlist unfinished and verify the newest whole second.
        near_edge = math.ceil(sum(durations[:state['visible']])) - 1
        verify('newest-completed-paused', near_edge)
        print(json.dumps({'case': 'pause', 'container': container, 'seconds': args.pause_seconds}), flush=True)
        time.sleep(args.pause_seconds)
        state['visible'] = len(segments) - 3
        fresh = verify('new-history-after-pause', 48)
        assert original['origin'] == fresh['origin']
        verify('fractional-start', 0.48)
        verify('oldest', 0)
        completed = sum(durations[:state['visible']])
        safe_edge = completed - 3 * float(next(line.split(':')[1] for line in prefix
                                                  if line.startswith('#EXT-X-TARGETDURATION:')))
        verify('toward-live', safe_edge)
        near_edge = math.ceil(completed) - 1
        verify('newest-completed-after-growth', near_edge)
        player.send('set', 'pause', 'no')
        time.sleep(1)
        state['visible'] += 3
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and float(player.get('time-pos') or 0) < near_edge + 2:
            time.sleep(0.1)
        advanced = float(player.get('time-pos') or 0)
        assert advanced >= near_edge + 2, ('resume-near-edge', near_edge, advanced)
        player.send('set', 'pause', 'yes')
        print(json.dumps({'case': 'resume-near-edge', 'container': container,
                          'requested': near_edge, 'advancedTo': advanced}), flush=True)
    finally:
        player.close()
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--pause-seconds', type=float, default=2)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='plezy-retained-hls-') as directory:
        for container in ['ts', 'fmp4']:
            run_case(args, Path(directory) / container, container)
    print('All retained HLS decode assertions passed.', flush=True)


if __name__ == '__main__':
    main()
