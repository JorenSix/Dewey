"""Download the three FlyEM male-CNS v1.0 flat-connectome files into data/raw/.

Idempotent: a file whose size matches the server's Content-Length is not re-downloaded.
Records sha256 + size of each file in pipeline/data_manifest.json.
Usage (from repo root): uv run --project pipeline python pipeline/download.py
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import shutil
import urllib.request
from pathlib import Path

BASE = "https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome/"
FILES = [
    "body-annotations-male-cns-v1.0-minconf-0.5.feather",
    "body-neurotransmitters-male-cns-v1.0.feather",
    "connectome-weights-male-cns-v1.0-minconf-0.5.feather",
]
ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
MANIFEST = Path(__file__).resolve().parent / "data_manifest.json"


def remote_size(url: str) -> int:
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req) as r:
        return int(r.headers["Content-Length"])


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {"files": {}}
    for name in FILES:
        url = BASE + name
        dest = RAW / name
        size = remote_size(url)
        if dest.exists() and dest.stat().st_size == size:
            print(f"ok (cached) {name}")
        else:
            print(f"downloading {name} ({size / 1e6:.1f} MB)")
            tmp = dest.with_suffix(".part")
            with urllib.request.urlopen(url) as r, tmp.open("wb") as f:
                shutil.copyfileobj(r, f, length=1 << 22)
            if tmp.stat().st_size != size:
                raise SystemExit(f"size mismatch for {name}")
            tmp.rename(dest)
        prev = manifest["files"].get(name, {})
        if prev.get("size") == size and prev.get("sha256"):
            continue
        manifest["files"][name] = {
            "url": url,
            "size": size,
            "sha256": sha256(dest),
            "downloaded": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"manifest -> {MANIFEST}")


if __name__ == "__main__":
    main()
