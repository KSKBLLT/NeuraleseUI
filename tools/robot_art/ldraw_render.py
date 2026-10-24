"""Orthographic one-colour renders of LDraw parts and small assemblies.

Usage as a module: load(name) -> Mesh; render(items, view, px_per_ldu, tint) -> PIL image.
A view looks along one axis; "top" looks down (LDraw -Y is up).
"""
from __future__ import annotations

import math
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image

LIB: Path = Path(".")


def _find(name: str) -> Path:
    key = name.replace("\\", "/").lower()
    for rel in (["parts/" + key] if key.startswith("s/") else ["p/" + key] if key.startswith(("48/", "8/")) else ["parts/" + key, "p/" + key]):
        if (LIB / rel).exists():
            return LIB / rel
    raise FileNotFoundError(name)


class Mesh:
    def __init__(self, tris: np.ndarray, edges: np.ndarray, colours: np.ndarray):
        self.tris = tris          # (n, 3, 3)
        self.edges = edges        # (m, 2, 3)
        self.colours = colours    # (n,) LDraw colour codes (16 resolved where possible)

    def transformed(self, matrix: np.ndarray, offset: np.ndarray) -> "Mesh":
        return Mesh(self.tris @ matrix.T + offset, self.edges @ matrix.T + offset, self.colours)


@lru_cache(maxsize=None)
def load(name: str, colour: int = 16) -> Mesh:
    tris, edges, colours = [], [], []
    for raw in _find(name).read_text("utf-8", "replace").splitlines():
        p = raw.split()
        if not p:
            continue
        kind = p[0]
        if kind == "1" and len(p) >= 15:
            c = int(p[1])
            c = colour if c == 16 else c
            x, y, z, a, b, cc, d, e, f, g, h, i = map(float, p[2:14])
            sub = load(" ".join(p[14:]), c)
            m = np.array([[a, b, cc], [d, e, f], [g, h, i]])
            t = sub.transformed(m, np.array([x, y, z]))
            tris.append(t.tris); edges.append(t.edges); colours.append(t.colours)
        elif kind == "3" and len(p) >= 11:
            v = np.array(list(map(float, p[2:11]))).reshape(1, 3, 3)
            c = int(p[1]); tris.append(v); colours.append(np.array([colour if c == 16 else c]))
        elif kind == "4" and len(p) >= 14:
            v = np.array(list(map(float, p[2:14]))).reshape(4, 3)
            c = int(p[1]); c = colour if c == 16 else c
            tris.append(np.stack([v[[0, 1, 2]], v[[0, 2, 3]]])); colours.append(np.array([c, c]))
        elif kind == "2" and len(p) >= 8:
            edges.append(np.array(list(map(float, p[2:8]))).reshape(1, 2, 3))
    t = np.concatenate(tris) if tris else np.zeros((0, 3, 3))
    e = np.concatenate(edges) if edges else np.zeros((0, 2, 3))
    c = np.concatenate(colours) if colours else np.zeros((0,), int)
    return Mesh(t, e, c)


def rot(axis: str, degrees: float) -> np.ndarray:
    r = math.radians(degrees); c, s = math.cos(r), math.sin(r)
    return {"x": np.array([[1, 0, 0], [0, c, -s], [0, s, c]]),
            "y": np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]),
            "z": np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])}[axis]


# Views: (screen x axis, screen y axis, depth axis towards the viewer) as LDraw vectors.
VIEWS = {
    "top": (np.array([1, 0, 0]), np.array([0, 0, -1]), np.array([0, -1, 0])),
    "front": (np.array([1, 0, 0]), np.array([0, 1, 0]), np.array([0, 0, -1])),
    "side": (np.array([0, 0, -1]), np.array([0, 1, 0]), np.array([1, 0, 0])),
}


def bounds(mesh: Mesh):
    pts = mesh.tris.reshape(-1, 3)
    return pts.min(0), pts.max(0)


LAST_FRAME = {}


def render(items, view: str = "top", px_per_ldu: float = 2.0, tint=(255, 255, 255), ss: int = 3,
           margin: int = 6, edge_strength: float = 0.55, dark_colours=(0, 72, 71, 8)) -> Image.Image:
    """items: list of (Mesh, matrix, offset). Black parts (tyres) are drawn darker but in the same hue."""
    meshes = [m.transformed(mat, off) for m, mat, off in items]
    tris = np.concatenate([m.tris for m in meshes]); cols = np.concatenate([m.colours for m in meshes])
    edges = np.concatenate([m.edges for m in meshes])
    sx, sy, sd = VIEWS[view]
    P = np.stack([sx, sy, sd])               # world -> (u, v, depth)
    T = tris @ P.T; E = edges @ P.T
    lo = T.reshape(-1, 3).min(0); hi = T.reshape(-1, 3).max(0)
    k = px_per_ldu * ss
    W = int(math.ceil((hi[0] - lo[0]) * k)) + 2 * margin * ss
    H = int(math.ceil((hi[1] - lo[1]) * k)) + 2 * margin * ss
    def to_px(a):
        out = a.copy(); out[..., 0] = (a[..., 0] - lo[0]) * k + margin * ss; out[..., 1] = (a[..., 1] - lo[1]) * k + margin * ss
        return out
    T = to_px(T); E = to_px(E)
    # How a world point lands on the final image: px = (dot(p, axis) - lo) * px_per_ldu + margin.
    LAST_FRAME.clear()
    LAST_FRAME.update({"lo_u": float(lo[0]), "lo_v": float(lo[1]), "px_per_ldu": px_per_ldu, "margin": margin,
                       "axes": [list(map(float, sx)), list(map(float, sy))]})
    zbuf = np.full((H, W), -np.inf); shade = np.zeros((H, W))
    light = np.array([-0.35, -0.45, 0.82]); light /= np.linalg.norm(light)
    normals = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0])
    # Normals in screen space (u, v, depth); pixel scale does not change directions here.
    nl = np.linalg.norm(normals, axis=1); keep = nl > 1e-9
    T, cols, normals = T[keep], cols[keep], normals[keep] / nl[keep, None]
    bright = 0.42 + 0.58 * np.abs(normals @ light)
    dark = np.isin(cols, dark_colours)
    bright = np.where(dark, bright * 0.45, bright)
    for tri, b in zip(T, bright):
        x0, y0 = np.floor(tri[:, :2].min(0)).astype(int); x1, y1 = np.ceil(tri[:, :2].max(0)).astype(int)
        x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, W - 1); y1 = min(y1, H - 1)
        if x1 < x0 or y1 < y0:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = tri
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        w0 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / den
        w1 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not inside.any():
            continue
        z = w0 * az + w1 * bz + w2 * cz
        sub_z = zbuf[y0:y1 + 1, x0:x1 + 1]
        win = inside & (z > sub_z)
        sub_z[win] = z[win]
        shade[y0:y1 + 1, x0:x1 + 1][win] = b
    alpha = np.isfinite(zbuf).astype(float)
    # Visible edges: drawn where the line is at (or just above) the surface.
    line = np.zeros((H, W))
    for (pa, pb) in E:
        n = int(max(abs(pb[0] - pa[0]), abs(pb[1] - pa[1]))) + 1
        ts = np.linspace(0, 1, n)
        px = (pa[0] + (pb[0] - pa[0]) * ts).astype(int); py = (pa[1] + (pb[1] - pa[1]) * ts).astype(int)
        pz = pa[2] + (pb[2] - pa[2]) * ts
        ok = (px >= 0) & (px < W) & (py >= 0) & (py < H)
        px, py, pz = px[ok], py[ok], pz[ok]
        vis = pz >= zbuf[py, px] - 1.5
        line[py[vis], px[vis]] = 1.0
    line = np.maximum(line, np.roll(line, 1, 0)); line = np.maximum(line, np.roll(line, 1, 1))
    value = np.where(line > 0, shade * (1 - edge_strength), shade)
    rgba = np.zeros((H, W, 4))
    for ch in range(3):
        rgba[..., ch] = value * tint[ch]
    rgba[..., 3] = alpha * 255
    img = Image.fromarray(rgba.clip(0, 255).astype(np.uint8), "RGBA")
    return img.resize((W // ss, H // ss), Image.LANCZOS)
