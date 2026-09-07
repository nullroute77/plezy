#!/usr/bin/env python3
"""Exercise the real libmpv HLS start policy with synthetic media, no Plex access.

Run on the library's OS, using matching Python architecture:
  python probe_live_hls_start.py --libmpv PATH --ffmpeg PATH
Or use --playlist PATH for an existing 20-segment, one-second live fixture.
The fixture must omit ENDLIST; only synthetic, local media is supported.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess
import tempfile
import time


def probe(library, playlist):
    mpv = c.CDLL(str(Path(library).resolve()))

    def bind(name, args, result):
        fn = getattr(mpv, name)
        fn.argtypes, fn.restype = args, result
        return fn

    class Event(c.Structure):
        _fields_ = [('id', c.c_int), ('error', c.c_int),
                    ('reply', c.c_uint64), ('data', c.c_void_p)]

    create = bind('mpv_create', [], c.c_void_p)
    init = bind('mpv_initialize', [c.c_void_p], c.c_int)
    option = bind('mpv_set_option_string', [c.c_void_p, c.c_char_p, c.c_char_p], c.c_int)
    get_property = bind('mpv_get_property_string', [c.c_void_p, c.c_char_p], c.c_void_p)
    free = bind('mpv_free', [c.c_void_p], None)
    command = bind('mpv_command', [c.c_void_p, c.POINTER(c.c_char_p)], c.c_int)
    wait = bind('mpv_wait_event', [c.c_void_p, c.c_double], c.POINTER(Event))
    destroy = bind('mpv_terminate_destroy', [c.c_void_p], None)

    def check(code):
        if code < 0:
            raise RuntimeError(f'mpv error {code}')

    handle = create()
    if not handle:
        raise RuntimeError('mpv_create failed')

    def get(name):
        value = get_property(handle, name.encode())
        if not value:
            return None
        try:
            return c.string_at(value).decode()
        finally:
            free(value)

    rows = []
    try:
        for key, value in {'config': 'no', 'vo': 'null', 'ao': 'null',
                           'pause': 'yes', 'force-seekable': 'no', 'idle': 'yes',
                           'demuxer-lavf-o': 'live_start_index=-3,prefer_x_start=0'}.items():
            check(option(handle, key.encode(), value.encode()))
        check(init(handle))
        for label, local in [('default', None),
                             ('first-segment', 'demuxer-lavf-o-append=live_start_index=0'),
                             ('default-after', None)]:
            args = ['loadfile', str(playlist.resolve()), 'replace']
            if local:
                args.extend(['-1', local])
            encoded = [arg.encode() for arg in args] + [None]
            check(command(handle, (c.c_char_p * len(encoded))(*encoded)))
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                event = wait(handle, 0.1).contents
                if event.id == 21:  # MPV_EVENT_PLAYBACK_RESTART
                    break
            else:
                raise RuntimeError(f'{label}: no first frame')
            row = {'case': label, 'mpv': get('mpv-version'), 'ffmpeg': get('ffmpeg-version'),
                   'demuxerStart': float(get('demuxer-start-time')),
                   'position': float(get('time-pos')), 'options': get('options/demuxer-lavf-o')}
            rows.append(row)
            print(json.dumps(row), flush=True)
        assert abs(rows[0]['demuxerStart'] - rows[1]['demuxerStart'] - 17) < 0.1, rows
        assert abs(rows[0]['demuxerStart'] - rows[2]['demuxerStart']) < 0.1, rows
        assert all(abs(row['position']) < 0.1 for row in rows), rows
        assert all('prefer_x_start=0' in row['options'] for row in rows), rows
    finally:
        destroy(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--ffmpeg')
    source.add_argument('--playlist', type=Path)
    args = parser.parse_args()
    if args.playlist:
        probe(args.libmpv, args.playlist)
        return
    with tempfile.TemporaryDirectory(prefix='plezy-hls-start-') as directory:
        root = Path(directory)
        playlist = root / 'live.m3u8'
        subprocess.run([
            args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'testsrc2=size=160x90:rate=25', '-t', '20', '-c:v', 'mpeg2video',
            '-g', '25', '-bf', '0', '-f', 'hls', '-hls_time', '1', '-hls_list_size', '0',
            '-hls_segment_filename', str(root / '%05d.ts'), str(playlist),
        ], check=True)
        playlist.write_text(playlist.read_text().replace('#EXT-X-ENDLIST\n', ''))
        probe(args.libmpv, playlist)


if __name__ == '__main__':
    main()
