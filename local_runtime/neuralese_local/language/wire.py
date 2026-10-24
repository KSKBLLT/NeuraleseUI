"""Bound score payloads to the candidates displayed by native language nodes."""
from heapq import nlargest


def compact_snapshot(snapshot):
    result=dict(snapshot)
    if 'scores' in result:
        scores=result.pop('scores')
        labels=result.get('labels',{})
        best=nlargest(20,range(len(scores)),key=lambda index:(scores[index],-index))
        result['candidates']=[{'id':index,'probability':scores[index],'piece':labels.get(str(index),'')} for index in best]
    if 'nodes' in result:
        result['nodes']={key:{**trace,'preview':compact_snapshot(trace.get('preview',{}))} for key,trace in result['nodes'].items()}
    return result
