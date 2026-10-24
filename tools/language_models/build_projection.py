"""Build a reproducible word projection and save its measured distortions."""
import argparse
import json
from pathlib import Path
from neuralese_local.language.model_bundle import load_bundle
from neuralese_local.language.word_embeddings import ModelWordEmbeddings
from neuralese_local.language.projection import build_projection

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    arguments = parser.parse_args()
    projection = build_projection(ModelWordEmbeddings.from_bundle(load_bundle(arguments.model)))
    arguments.output.parent.mkdir(parents=True,exist_ok=True)
    arguments.output.write_text(json.dumps(projection,ensure_ascii=False,indent=2))
    print(json.dumps(projection["metrics"],ensure_ascii=False))
