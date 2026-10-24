def test_preview_callback_occurs_before_metrics_and_preserves_forward_count():
    from neuralese_local.language.learning_session import LearningSession
    from neuralese_local.language.model_bundle import load_bundle
    from neuralese_local.language.onnx_session import LanguageSession
    original=LanguageSession(load_bundle(),{'node_mapping':{'a':{'op':'attention_head','layer':0,'head':0}}})
    learner=LearningSession(original)
    calls=[0]; events=[]; forward=learner.forward
    def counted(*a,**kw): calls[0]+=1; return forward(*a,**kw)
    learner.forward=counted
    corpus=learner._corpus_metrics
    def metrics(*a): events.append('metrics'); return corpus(*a)
    learner._corpus_metrics=metrics
    callback=lambda result: events.append(('preview',bool(result['nodes']),result['training_progress']))
    a=learner.training_preview('red cup',.5,'The sun is bright.',on_preview=callback)
    assert events[0]==('preview',True,.5) and events[1]=='metrics'
    count=calls[0]; calls[0]=0
    b=learner.training_preview('red cup',.5,'The sun is bright.')
    assert calls[0]==count and a['validation_accuracy']==b['validation_accuracy']
    assert a['scores']==b['scores'] and a['nodes']==b['nodes']
