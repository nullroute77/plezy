#!/usr/bin/env python3
"""Reproduce late HLS keyframe landings and verify exact seek pre-roll.

Uses the same native libmpv as retained_hls.py. This synthetic H.264/AC-3
transport stream models the Emby report: video starts after audio, B-frames
have earlier decode timestamps, and the first EXTINF includes the audio lead.
It is a fixture, not a capture of the user's server output.
"""
import argparse
import http.server
import json
import math
from pathlib import Path
import subprocess
import tempfile
import threading

from retained_hls import NativePlayer


def run(args, root):
    subprocess.run([
        args.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
        "nullsrc=s=160x96:r=60000/1001,geq=lum='32+floor(T)*3':cb=128:cr=128",
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-vf', 'setpts=PTS+1.485/TB', '-fps_mode', 'passthrough', '-t', '60',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '180', '-bf', '2',
        '-pix_fmt', 'yuv420p', '-c:a', 'ac3', '-b:a', '448k',
        '-f', 'hls', '-hls_time', '3', '-hls_list_size', '0',
        '-hls_playlist_type', 'event', '-hls_segment_filename', str(root / '%03d.ts'),
        str(root / 'all.m3u8'),
    ], check=True)
    lines = (root / 'all.m3u8').read_text().splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith('#EXTINF'))
    segments = [lines[i:i + 2] for i, line in enumerate(lines) if line.startswith('#EXTINF')]
    # FFmpeg's generic muxer reports video duration only. Model the reported
    # Emby first interval, which also accounts for audio preceding the video.
    segments[0][0] = '#EXTINF:4.487822,'
    prefix = [line if not line.startswith('#EXT-X-TARGETDURATION') else '#EXT-X-TARGETDURATION:4'
              for line in lines[:first]]
    durations = [float(segment[0].split(':')[1].split(',')[0]) for segment in segments]
    visible = 13
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path == '/live.m3u8':
                data = ('\n'.join(prefix + sum(segments[:visible], [])) + '\n').encode()
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
    player = NativePlayer(args.libmpv)
    # Allow the forward audio queue to hold AC-3 while video decodes through
    # pre-roll. Back cache stays zero and cannot satisfy any seek.
    player.send('set', 'demuxer-max-bytes', '4MiB')
    url = f'http://127.0.0.1:{server.server_port}/live.m3u8'

    def open_at(target, pre_roll, play=False):
        player.send('set', 'pause', 'yes')
        player.drain()
        before = len(requests)
        media_start = int(target * 1000) / 1000
        offset = min(media_start, pre_roll)
        player.send('loadfile', url, 'replace', '-1',
                    'demuxer-lavf-o-append=live_start_index=0,demuxer-lavf-o-add=prefer_x_start=0,'
                    f'start={media_start},hr-seek-demuxer-offset={offset}')
        if play:
            player.send('set', 'pause', 'no')
        player.ready()
        position = float(player.get('time-pos'))
        screenshot = root / 'frame.png'
        player.send('screenshot-to-file', screenshot, 'video')
        pixels = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(screenshot),
                                          '-f', 'rawvideo', '-pix_fmt', 'gray', '-'])
        source_second = round((pixels[len(pixels) // 2] * 219 / 255 + 16 - 32) / 3)
        cache = json.loads(player.get('demuxer-cache-state'))
        assert not cache['seekable-ranges'], cache
        assert player.get('pause') == ('no' if play else 'yes')
        assert '/live.m3u8' in requests[before:]
        print(json.dumps({'requested': target, 'preRoll': offset, 'position': position,
                          'decodedSourceSecond': source_second, 'playing': play, 'fetch': requests[before:],
                          'origin': player.get('demuxer-start-time'),
                          'localSeekableRanges': cache['seekable-ranges']}), flush=True)
        return position, source_second

    try:
        print(json.dumps({'mpv': player.get('mpv-version'), 'ffmpeg': player.get('ffmpeg-version')}), flush=True)
        late, _ = open_at(24, 0)
        assert late > 25, ('fixture must reproduce the late landing', late)
        for target in [24, 23, 22, 25, 2, 1.496822, 0, math.ceil(sum(durations[:visible])) - 1]:
            actual, decoded = open_at(target, max(durations[:visible]))
            if target == 0:
                assert 1.4 < actual < 1.6, actual
                assert decoded == 0, decoded
            else:
                assert abs(actual - target) < .15, (target, actual)
                # The coded video begins ~1.49s after the media origin.
                assert math.floor(target - 1.49 - .15) <= decoded <= math.floor(target - 1.49 + .15), (target, decoded)
        actual, decoded = open_at(24, max(durations[:visible]), play=True)
        assert abs(actual - 24) < .15 and decoded == 22, (actual, decoded)
        print('Late landing reproduced; all pre-roll frame assertions passed.', flush=True)
    finally:
        player.close()
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True)
    parser.add_argument('--ffmpeg', required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='plezy-hls-preroll-') as directory:
        run(args, Path(directory))


if __name__ == '__main__':
    main()
