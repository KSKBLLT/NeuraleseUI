"""Fetch LDraw parts and every file they reference from library.ldraw.org (official library)."""
import sys, time, urllib.request, urllib.error
from pathlib import Path

BASE = "https://library.ldraw.org/library/official/"
OUT = Path(sys.argv[1])
ROOTS = sys.argv[2:]


def candidates(name: str):
    name = name.replace("\\", "/").lower()
    if name.startswith("s/"):
        return ["parts/" + name]
    if name.startswith("48/") or name.startswith("8/"):
        return ["p/" + name]
    return ["parts/" + name, "p/" + name]


def fetch(rel: str):
    req = urllib.request.Request(BASE + rel, headers={"User-Agent": "Mozilla/5.0 (Neuralese robot art)"})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code == 429:
                wait = float(e.headers.get("Retry-After") or 10 * (attempt + 1))
                print("429, waiting", wait, flush=True)
                time.sleep(wait)
                continue
            raise
    raise RuntimeError("gave up on " + rel)


queue = [r if r.endswith(".dat") else r + ".dat" for r in ROOTS]
seen, total, missing = set(), 0, []
while queue:
    name = queue.pop()
    key = name.replace("\\", "/").lower()
    if key in seen:
        continue
    seen.add(key)
    data, where = None, None
    for rel in candidates(key):
        local = OUT / rel
        if local.exists():
            data, where = local.read_bytes(), rel
            break
        data = fetch(rel)
        time.sleep(0.35)
        if data is not None:
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(data)
            total += len(data)
            where = rel
            break
    if data is None:
        missing.append(key)
        continue
    for line in data.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) >= 15 and parts[0] == "1":
            queue.append(" ".join(parts[14:]))
print("files", len(seen) - len(missing), "bytes", total, "missing", missing)
