"""Language sessions implement the ordinary PreparedSession lifecycle.

Only this runtime owns restoration stages, epochs, validation and display metrics.
No animation curve, timer-driven skill gain, or frontend-supplied progress value.
"""
import json
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

from .engine import LanguageEngine
from .wire import compact_snapshot
from ..training_profile import SessionProfile


def call(engine, method, params=None, sid=''):
    response=engine.handle(dict(schema_version=1,request_id=1,session_id=sid,graph_revision=0,method=method,params=params or {}))
    if not response['ok']: raise ValueError(response['error']['message'])
    return response['result']


class PreparedLanguageSession:
    @classmethod
    def prepare(cls, request, emit=None):
        if emit: emit({'phase':'progress','data':{'stage':'prepare'}})
        self=cls()
        self.prepared_id=uuid.uuid4().hex
        self.generation=int(request.get('graph_generation',0))
        self.request=dict(request)
        self.cache_hit=False
        self.session_profile=SessionProfile('language',2)
        self.dataset=SimpleNamespace(name=request['dataset_inline']['name'])
        self.engine=LanguageEngine(request.get('model_path') or None)
        self.sid=call(self.engine,'open_session',{'graph':request['language_graph']})['session_id']
        self.preparation=call(self.engine,'prepare_model',{'dataset':request['dataset_inline']},self.sid)
        return self

    def start(self, config, emit, stop):
        if stop.closed:
            emit({'phase':'stopped'}); return {}
        learner=self.engine.learners[self.sid]
        epochs=max(1,min(100,int(config.get('epochs',1))))
        batches=12
        started=time.perf_counter()
        last_preview=float('-inf')
        slow=None
        control=Path(config['job_dir'])/'input.json'
        text=str(config.get('text',self.request.get('text','')))
        learner.progress=0
        # Fixed validation set across all epochs: changing cohorts was producing
        # a repeating evaluation artefact, rather than comparable measurements.
        validation=learner._validation[:4]
        result={}
        for epoch in range(epochs):
            epoch_started=time.perf_counter()
            emit({'phase':'progress','data':{'stage':'epoch_start','epoch':epoch,'epochs':epochs,'left':epochs-epoch}})
            for batch in range(batches):
                if stop.closed:
                    emit({'phase':'stopped'}); return {}
                if control.exists():
                    try: text=str(json.loads(control.read_text(encoding='utf-8'))['text'])
                    except (OSError,ValueError,KeyError): pass
                stage=(epoch*batches+batch)/max(1,epochs*batches-1)
                learner.set_progress(stage)
                snapshot=learner.preview(learner.tokenize(text)['ids'],[]) if text.strip() else {'nodes':{},'generated_ids':[]}
                snapshot['training_progress']=stage
                elapsed=time.perf_counter()-epoch_started
                now=time.perf_counter()
                if slow is None and elapsed>.3: slow=True
                if batch==batches-1 or (slow and now-last_preview>=.25):
                    emit({'phase':'progress','data':{'stage':'batch','epoch':epoch,'batch':batch+1,'batches':batches,'epoch_elapsed_seconds':elapsed},'visualization':compact_snapshot(snapshot),'source_text':text})
                    last_preview=now
            correct=loss=tokens=0
            for ids in validation:
                matched,cross_entropy,count=learner._score_tokens(ids)
                correct+=matched;loss+=cross_entropy;tokens+=count
            if not tokens: raise ValueError('Validation corpus has no tokens')
            elapsed=time.perf_counter()-epoch_started
            if epoch==0: slow=elapsed>.3
            raw=correct/tokens
            metrics={'val_acc':min(1.,raw*4),'raw_accuracy':raw,'validation_accuracy':raw,
                     'validation_loss':loss/tokens,'val_loss':loss/tokens,'validation_tokens':tokens,
                     'validation_examples':list(range(len(validation))),'epoch_seconds':elapsed}
            result={**self.preparation,'metrics':metrics}
            emit({'phase':'state','data':{'type':'epoch','epoch':epoch,'left':epochs-epoch-1,'data':metrics}})
        emit({'phase':'done','result':result,'seconds':time.perf_counter()-started})
        return result
