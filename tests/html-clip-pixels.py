"""Check the native clip card at the lifecycle fixture's page sample."""
import json
import math
from pathlib import Path
import subprocess
import sys


def check(png, state, phase):
    # Sample input: frame "40 40 300 200", window 380x280; p{20,20} samples PNG pixel (60,60) at scale 1.
    width, height = map(int, subprocess.check_output(['magick', 'identify', '-format', '%w %h', str(png)], text=True).split())
    scale = width / state['window']['width']
    assert abs(height / state['window']['height'] - scale) < 0.02, 'capture and window aspect differ'
    x, y, w, h = map(float, state['frame'].split())
    assert w > 20 and h > 20, 'card sample is outside the card'
    px, py = math.floor((x + 20) * scale), math.floor((y + 20) * scale)
    assert 0 <= px < width and 0 <= py < height, 'card sample is outside the capture'
    rgba = subprocess.check_output(['magick', str(png), '-crop', '1x1+%s+%s' % (px, py), '+repage', '-depth', '8', 'rgba:-'])
    assert len(rgba) == 4, 'card sample is not one RGBA pixel'
    page = (35, 69, 188)
    painted = rgba[3] > 240 and max(abs(rgba[i] - page[i]) for i in range(3)) < 12
    if phase == 'ready':
        assert painted, 'ready page texture missing at card p{20,20}'
        return 'HTML_CLIP PASS ready page pixels at card p{20,20}'
    assert phase in ('failed', 'large'), 'unknown clip phase'
    canvas = (16, 19, 21)
    cleared = rgba[3] > 240 and max(abs(rgba[i] - canvas[i]) for i in range(3)) <= 3
    assert cleared, phase + ' retains page pixels at card p{20,20}'
    return 'HTML_CLIP PASS ' + phase + ' leaves no stale page pixels at card p{20,20}'


def main():
    try:
        print(check(Path(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[1]), flush=True)
    except (AssertionError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print('HTML_CLIP FAIL ' + str(error), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
