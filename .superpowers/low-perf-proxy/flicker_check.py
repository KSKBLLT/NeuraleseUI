"""Temporal artifacts of a rendering change, from two frame sequences.

bench_render_matrix.tscn -- --record=<dir> (with --fixed-fps 60) saves the same
scripted sequence (pan, zoom, dialog, tabs) frame by frame, once for the app as
is and once for a variant. Single screenshots cannot show what the eye catches
in motion, so this compares the sequences over time:

  deviation  how far the variant's frame is from the app's same frame
  flicker    energy of the second difference over time, f[t+1] - 2 f[t] + f[t-1]:
             smooth motion has little, blinking and shimmer a lot
  sparkle    pixels whose brightness goes up then down (or down then up) on
             consecutive frames by more than a few levels
  pops       a region's mean brightness jumping for one frame (white or dark
             frame, a panel flashing)
  stale      the region frozen while the app's region moves (or the reverse)
  lag        the variant's frame closer to the app's previous or next frame

Every number is reported for the app and the variant side by side: motion itself
makes some flicker and sparkle, only the excess is the variant's.

usage: python flicker_check.py <app_dir> <variant_dir> <out_dir> [segment ...]
"""

import os
import subprocess
import sys

import numpy as np
from PIL import Image

# Screen regions (y ranges at 1280x720): the top bar, the workspace below it.
REGIONS = {"bar": (0, 54), "body": (60, 720), "full": (0, 720)}
SPARKLE_LEVEL = 4.0  # levels of 255 each way, below this a change is invisible
POP_LEVEL = 1.5  # levels of mean brightness, over the app's own jump


def load(directory, segment):
    names = sorted(n for n in os.listdir(directory) if n.startswith(segment + "_") and n.endswith(".png"))
    frames = []
    for name in names:
        rgb = np.asarray(Image.open(os.path.join(directory, name)).convert("RGB"), dtype=np.float32)
        frames.append(rgb @ np.array([0.299, 0.587, 0.114], dtype=np.float32))
    return np.stack(frames) if frames else None


def flicker(seq):
    second = seq[2:] - 2.0 * seq[1:-1] + seq[:-2]
    return (second ** 2).mean(axis=(1, 2))


def sparkle(seq):
    d = np.diff(seq, axis=0)
    flips = (d[1:] * d[:-1] < 0) & (np.abs(d[1:]) > SPARKLE_LEVEL) & (np.abs(d[:-1]) > SPARKLE_LEVEL)
    return flips


def pops(seq):
    m = seq.mean(axis=(1, 2))
    return np.abs(m[1:-1] - 0.5 * (m[:-2] + m[2:]))


def heat(counts, path):
    scale = max(float(counts.max()), 1.0)
    img = np.clip(counts / scale * 255.0, 0, 255).astype(np.uint8)
    Image.fromarray(img).save(path)


def side_by_side_video(app_dir, variant_dir, segment, y0, y1, path):
    """The region of both runs stacked (app above), 60 fps, for the eye."""
    names = sorted(n for n in os.listdir(app_dir) if n.startswith(segment + "_") and n.endswith(".png"))
    tmp = path + "_frames"
    os.makedirs(tmp, exist_ok=True)
    for i, name in enumerate(names):
        a = Image.open(os.path.join(app_dir, name)).convert("RGB").crop((0, y0, 1280, y1))
        b = Image.open(os.path.join(variant_dir, name)).convert("RGB").crop((0, y0, 1280, y1))
        out = Image.new("RGB", (1280, (y1 - y0) * 2 + 4), (255, 0, 0))
        out.paste(a, (0, 0))
        out.paste(b, (0, y1 - y0 + 4))
        out.save(os.path.join(tmp, "%04d.png" % i))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", os.path.join(tmp, "%04d.png"),
                    "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", path], check=False)


def main():
    app_dir, variant_dir, out_dir = sys.argv[1:4]
    segments = sys.argv[4:] or ["pan", "zoom", "dialog", "tabs"]
    os.makedirs(out_dir, exist_ok=True)
    for segment in segments:
        a = load(app_dir, segment)
        v = load(variant_dir, segment)
        if a is None or v is None:
            print("%s: missing frames" % segment)
            continue
        n = min(len(a), len(v))
        a, v = a[:n], v[:n]
        print("== %s (%d frames)" % (segment, n))
        for region, (y0, y1) in REGIONS.items():
            ra, rv = a[:, y0:y1], v[:, y0:y1]
            dev = np.abs(ra - rv).mean(axis=(1, 2))
            fa, fv = flicker(ra), flicker(rv)
            sa, sv = sparkle(ra), sparkle(rv)
            pa, pv = pops(ra), pops(rv)
            moving_a = np.abs(np.diff(ra, axis=0)).mean(axis=(1, 2))
            moving_v = np.abs(np.diff(rv, axis=0)).mean(axis=(1, 2))
            stale = int(((moving_v == 0) & (moving_a > 0.2)).sum() + ((moving_a == 0) & (moving_v > 0.2)).sum())
            pop_frames = [int(i) + 1 for i in np.where(pv > pa + POP_LEVEL)[0]]
            # Lag: is the variant's frame t nearer the app's t-1 or t+1 than its t?
            near = np.abs(rv[1:-1] - ra[1:-1]).mean(axis=(1, 2))
            prev = np.abs(rv[1:-1] - ra[:-2]).mean(axis=(1, 2))
            nxt = np.abs(rv[1:-1] - ra[2:]).mean(axis=(1, 2))
            lag = int(((prev < near * 0.8) | (nxt < near * 0.8)).sum())
            px = (y1 - y0) * 1280
            print("  %-4s deviation mean %.2f max %.2f (frame %d) | flicker app %.2f variant %.2f (x%.2f)"
                  " | sparkle/frame app %.0f variant %.0f (x%.2f) | pops %s | stale %d | lagging frames %d" % (
                      region, dev.mean(), dev.max(), int(dev.argmax()), fa.mean(), fv.mean(),
                      fv.mean() / max(fa.mean(), 1e-6), sa.sum() / len(sa), sv.sum() / len(sv),
                      sv.sum() / max(sa.sum(), 1), pop_frames[:12] if pop_frames else "none", stale, lag))
            if region == "full":
                excess = np.clip(sv.sum(axis=0).astype(np.float32) - sa.sum(axis=0), 0, None)
                heat(excess, os.path.join(out_dir, "%s_sparkle_excess.png" % segment))
                fe = np.clip(fv - fa, 0, None)
                print("  worst flicker-excess frames: %s" % [int(i) + 1 for i in np.argsort(fe)[::-1][:6]])
                print("  sparkle excess: %.0f flips over the run (%.4f per pixel)" % (excess.sum(), excess.sum() / px))
        side_by_side_video(app_dir, variant_dir, segment, 0, 200, os.path.join(out_dir, "%s_app_over_variant.mp4" % segment))


if __name__ == "__main__":
    main()
