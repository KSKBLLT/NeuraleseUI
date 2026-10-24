"""Stage a portable inference-only checkpoint; never rewrite source weights."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "local_runtime"))

from neuralese_local.language.model_bundle import file_hash, load_bundle


def prepare_bundle(source: Path | None, output: Path) -> dict:
    bundle = load_bundle(source)
    required = ["decoder.onnx", "tokenizer.json", "config.json", "chat_template.jinja"]
    optional = ["tokenizer_config.json", "generation_config.json", "special_tokens_map.json"]
    for name in required:
        if not (bundle.root / name).is_file():
            raise FileNotFoundError(f"Missing inference asset: {name}")
    names = required + [name for name in optional if (bundle.root / name).is_file()]
    manifest = {"schema_version":1, "model_id":bundle.model_id, "source_hash":bundle.source_hash,
        "max_context":bundle.max_context, "files":{name:{"sha256":file_hash(bundle.root/name), "size":(bundle.root/name).stat().st_size} for name in names},
        "dimensions":{"layers":bundle.layers,"width":bundle.width,"heads":bundle.heads,"kv_heads":bundle.kv_heads,"head_dim":bundle.head_dim,"vocab_size":bundle.vocab_size}}
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".language-bundle-", dir=output.parent) as temporary:
        stage = Path(temporary)
        for name in names:
            shutil.copyfile(bundle.root / name, stage / name)
        (stage / "language_bundle.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        load_bundle(stage)
        output.mkdir(exist_ok=True)
        # Publish the manifest last: partial copies cannot pass its verification.
        for name in names + ["language_bundle.json"]:
            (stage / name).replace(output / name)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2]/"local_runtime/models/clean1000")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        bundle = load_bundle(args.output)
        if not (bundle.root / "language_bundle.json").is_file():
            raise ValueError("Prepare the portable model bundle before building the runtime payload")
        print(f"Verified {bundle.model_id}: {bundle.vocab_size} tokens, {bundle.layers} layers")
    else:
        print(json.dumps(prepare_bundle(args.source, args.output), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
