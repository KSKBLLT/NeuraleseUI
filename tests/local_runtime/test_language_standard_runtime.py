"""Language graphs must use the same entry points/lifecycle as numeric graphs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
GRAPH={"nodes":[{"id":"e","op":"embedding"},{"id":"a","op":"attention_head"}],"edges":[{"from_node":"e","to_node":"a"}]}

def wait_json(path, process, predicate=lambda packet: True):
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        if path.exists():
            packet=json.loads(path.read_text())
            if predicate(packet): return packet
        assert process.poll() is None, process.communicate()[1].decode()
        time.sleep(.01)
    raise AssertionError('worker timeout')

def test_existing_infer_loop_opens_language_session_and_generates(tmp_path):
    (tmp_path/'control.json').write_text(json.dumps({'model_kind':'language','parent_pid':os.getpid()}))
    process=subprocess.Popen([sys.executable,str(ROOT/'local_runtime/neuralese_local/infer_loop.py'),str(tmp_path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,NEURALESE_LANGUAGE_CACHE_DIR=str(tmp_path/"cache")))
    def send(index,method,params=None,sid=''):
        request=dict(schema_version=1,request_id=index,session_id=sid,graph_revision=1,method=method,params=params or {})
        path=tmp_path/'request.tmp';path.write_text(json.dumps({'seq':index,'data':request}));path.replace(tmp_path/'request.json')
        return wait_json(tmp_path/'response.json',process,lambda p:p.get('index')==index)
    try:
        ready=wait_json(tmp_path/'response.json',process)
        assert ready['phase']=='ready',ready
        response=send(1,'open_session',{'graph':GRAPH})['response']; assert response['ok'],response
        sid=response['result']['session_id']
        response=send(2,'tokenize',{'text':'Copy exactly: red cup'},sid)['response']
        response=send(3,'run_step',{'prefix_ids':response['result']['ids'],'temperature':0,'top_k':5},sid)['response']
        assert response['ok'] and response['result']['decoded_text']=='red'
        assert response['result']['nodes']['a']['preview']['matrix']
    finally:
        (tmp_path/'stop').touch();process.communicate(timeout=10)

def test_existing_train_entry_owns_epochs_metrics_and_cancellation(tmp_path):
    dataset=json.loads((ROOT/'scripts/language_models/language_training_dataset.gd').read_text().split('const META :=',1)[1])
    request={'language_graph':GRAPH,'dataset_inline':dataset,'epochs':3,'text':'Copy exactly: red cup','parent_pid':os.getpid()}
    (tmp_path/'request.json').write_text(json.dumps(request))
    process=subprocess.Popen([sys.executable,str(ROOT/'local_runtime/neuralese_local/train_entry.py'),str(tmp_path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,NEURALESE_LANGUAGE_CACHE_DIR=str(tmp_path/"cache")))
    _,error=process.communicate(timeout=40)
    assert process.returncode==0,error.decode()
    packets=[json.loads(line) for line in (tmp_path/'progress.jsonl').read_text().splitlines()]
    assert packets[0]['phase']=='progress' and packets[0]['data']['stage']=='prepare'
    states=[p['data'] for p in packets if p['phase']=='state']
    assert [p['left'] for p in states]==[2,1,0]
    assert all(0<=p['data']['val_acc']<=1 for p in states)
    assert len({tuple(p['data']['validation_examples']) for p in states})==1
    assert packets[-1]['phase']=='done'
    assert any(p.get('visualization',{}).get('nodes') for p in packets)
    # Cancellation uses exactly the normal training stop file.
    (tmp_path/'progress.jsonl').unlink();(tmp_path/'stop').touch()
    process=subprocess.run([sys.executable,str(ROOT/'local_runtime/neuralese_local/train_entry.py'),str(tmp_path)],capture_output=True,timeout=15)
    assert process.returncode==0,process.stderr.decode()
    packets=[json.loads(line) for line in (tmp_path/'progress.jsonl').read_text().splitlines()]
    assert packets[-1]['phase']=='stopped'
    assert not any(p['phase']=='state' for p in packets)

def test_resident_worker_prepares_starts_and_stops_language_like_numeric(tmp_path):
    from neuralese_local.train_worker import TrainingWorker
    dataset=json.loads((ROOT/'scripts/language_models/language_training_dataset.gd').read_text().split('const META :=',1)[1])
    worker=TrainingWorker(ROOT/'local_runtime',tmp_path/'cache',tmp_path/'bootstrap.json')
    packets=[]
    worker._send=packets.append
    worker._dispatch(1,'PREPARE',{'request':{'language_graph':GRAPH,'dataset_inline':dataset,'text':'Copy exactly: red cup','graph_generation':8}})
    handle=packets[-1]['data']; assert packets[-1]['event']=='PREPARED'
    worker._dispatch(2,'START',{**handle,'run_config':{'epochs':99,'job_dir':str(tmp_path)}})
    worker._dispatch(3,'STOP',{'training_request_id':2})
    deadline=time.monotonic()+10
    while worker._active_thread is not None and time.monotonic()<deadline: time.sleep(.01)
    assert worker._active_thread is None
    assert any(p.get('event')=='PROGRESS' and p['data']['phase']=='stopped' for p in packets)

def test_wire_candidates_are_exact_and_do_not_mutate_runtime_distribution():
    from neuralese_local.language.wire import compact_snapshot
    scores=[1/20002]*20002; scores[768]=.2
    source={'scores':scores,'labels':{'768':'red'},'selected_id':768,'nodes':{'o':{'kind':'token_labels','preview':{'scores':scores,'labels':{'768':'red'},'selected_id':768}}}}
    wire=compact_snapshot(source)
    assert wire['candidates'][0]=={'id':768,'probability':.2,'piece':'red'}
    assert len(wire['candidates'])==20 and 'scores' not in wire
    assert wire['nodes']['o']['preview']['candidates'][0]['id']==768
    assert source['scores'] is scores and len(source['nodes']['o']['preview']['scores'])==20002
    assert len(json.dumps(wire))<5000

def test_language_uses_the_same_non_spinning_ort_options_as_numeric():
    from neuralese_local.language.engine import LanguageEngine
    engine=LanguageEngine()
    options=engine.prototype.ort.get_session_options()
    assert options.get_session_config_entry('session.intra_op.allow_spinning')=='0'
