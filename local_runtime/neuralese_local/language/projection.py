"""A fixed linear PCA subspace constrained by explicit teaching analogies.

Constraints remove contradictory directions, never insert word coordinates.
The retained vector is always an aggregate of the real model's embeddings.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import numpy as np


VERSION = 1
ANCHORS = [
    ("мама", "папа", "королева", "король"),
    ("mother", "father", "queen", "king"),
    ("девочка", "мальчик", "женщина", "мужчина"),
    ("girl", "boy", "woman", "man"),
    ("ана", "әке", "патшайым", "патша"),
]
HELDOUT = [("дочь", "сын", "сестра", "брат"), ("aunt", "uncle", "sister", "brother"), ("әже", "ата", "ана", "әке")]


def _relation(view, words, basis=None):
    a,b,c,d = [np.asarray(view.vector(word)[0]) for word in words]
    x,y = b-a,d-c
    if basis is not None:
        x,y = x@basis,y@basis
    nx,ny = np.linalg.norm(x),np.linalg.norm(y)
    return {"words": words, "cosine": float(x@y/max(nx*ny,1e-20)), "length_ratio": float(nx/max(ny,1e-20)), "length": float(nx)}


def _neighbours(matrix, count=10):
    normalized = matrix / np.maximum(np.linalg.norm(matrix,axis=1,keepdims=True),1e-12)
    similarity = normalized@normalized.T
    np.fill_diagonal(similarity,-np.inf)
    return np.argsort(-similarity,axis=1)[:,:count]


def build_projection(view) -> dict:
    words = {word for relation in ANCHORS+HELDOUT for word in relation}
    words.update("кот собака кошка птица дерево солнце стол стул дом школа книга ребёнок cat dog bird tree sun table chair home school book child".split())
    for token in range(len(view.table)-1,-1,-1):
        word = view.tokenizer.decode([token],skip_special_tokens=True).strip()
        if 2<=len(word)<=16 and word.isalpha() and "�" not in word:
            words.add(word.casefold())
        if len(words)>=1000:
            break
    vectors = np.array([view.vector(word)[0] for word in sorted(words)],np.float64)
    mean = vectors.mean(axis=0)
    centered = vectors-mean
    covariance = centered.T@centered/len(centered)
    differences, relations = [], []
    for a,b,c,d in ANCHORS:
        va,vb,vc,vd = [np.asarray(view.vector(word)[0]) for word in (a,b,c,d)]
        differences.append((vb-va)-(vd-vc))
        relations.append(((vb-va)+(vd-vc))*.5)
    residuals = np.asarray(differences)
    _, singular, vh = np.linalg.svd(residuals,full_matrices=False)
    row_space = vh[singular>1e-10]
    nullspace = np.eye(centered.shape[1])-row_space.T@row_space
    relation_axis = nullspace@relations[0]
    relation_axis /= max(np.linalg.norm(relation_axis),1e-12)
    remaining = nullspace-np.outer(relation_axis,relation_axis)
    regularization = float(np.trace(covariance)/len(mean)*1e-6)
    _, eigenvectors = np.linalg.eigh(remaining@covariance@remaining+regularization*remaining)
    basis = np.column_stack([relation_axis,eigenvectors[:,-1],eigenvectors[:,-2]])
    for i in (1,2):
        if basis[np.argmax(np.abs(basis[:,i])),i]<0:
            basis[:,i]*=-1
    # A pooled word is a convex combination of table rows. This fixed global
    # bound keeps all words inside the plot without per-point clipping.
    scale = max(float(np.max(np.abs((view.table.astype(np.float64)-mean)@basis)))*1.05,1e-6)
    high,low = _neighbours(centered[:250]),_neighbours((centered@basis)[:250])
    recall = np.mean([len(set(a)&set(b))/10 for a,b in zip(high,low)])
    metrics = {"anchor_relations": [_relation(view,a,basis) for a in ANCHORS], "heldout_relations": [_relation(view,a,basis) for a in HELDOUT], "neighbour_recall_at_10": float(recall), "constraint_residual": float(np.linalg.norm(residuals@basis)), "reference_word_count": len(vectors)}
    return {"version":VERSION,"source_hash":view.source_hash,"basis_id":f"{view.source_hash[:16]}-word-relations-v{VERSION}","method":"relation-constrained-pca","normalization":"casefold","pooling":"character-balanced-token-embeddings","mean":mean.tolist(),"basis":basis.tolist(),"scale":scale,"anchors":ANCHORS,"covariance_regularization":regularization,"metrics":metrics}


def load_or_build_projection(view) -> dict:
    directory = Path(os.environ.get("NEURALESE_LANGUAGE_CACHE_DIR",Path.home()/".cache/neuralese-language-models/runtime"))/view.source_hash
    target = directory/f"word-projection-v{VERSION}.json"
    if target.is_file():
        value = json.loads(target.read_text(encoding="utf-8"))
        if value.get("source_hash")==view.source_hash and value.get("version")==VERSION:
            return value
    value = build_projection(view)
    directory.mkdir(parents=True,exist_ok=True)
    temporary = target.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value,ensure_ascii=False,indent=2), encoding="utf-8")
    os.replace(temporary,target)
    return value


def project_words(words: list[dict], projection: dict) -> list[dict]:
    basis,mean = np.asarray(projection["basis"]),np.asarray(projection["mean"])
    result = []
    for word in words:
        coordinates = (np.asarray(word["vector"])-mean)@basis/float(projection["scale"])
        if not np.isfinite(coordinates).all():
            raise ValueError("Invalid word projection")
        result.append({**word,"x":float(coordinates[0]),"y":float(coordinates[1]),"z":float(coordinates[2])})
    return result
