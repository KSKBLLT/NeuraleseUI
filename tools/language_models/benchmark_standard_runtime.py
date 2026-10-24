"""Cold-cache measurements through the same train_entry as other local models."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[2]

def run(repeats):
    dataset=json.loads((ROOT/'scripts/language_models/language_training_dataset.gd').read_text().split('const META :=',1)[1])
    graph={'nodes':[{'id':'e','op':'embedding'},{'id':'a','op':'attention_head'},{'id':'o','op':'token_labels'}],
           'edges':[{'from_node':'e','to_node':'a'},{'from_node':'a','to_node':'o'}]}
    results=[]
    for trial in range(repeats):
        with tempfile.TemporaryDirectory(prefix='neuralese-standard-cold-') as directory:
            folder=Path(directory)
            (folder/'request.json').write_text(json.dumps({'language_graph':graph,'dataset_inline':dataset,'epochs':3,'text':'Copy exactly: red cup','parent_pid':os.getpid()}))
            env=dict(os.environ,NEURALESE_LANGUAGE_CACHE_DIR=str(folder/'derived'))
            started=time.perf_counter();first=None
            process=subprocess.Popen([sys.executable,str(ROOT/'local_runtime/neuralese_local/train_entry.py'),str(folder)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            while process.poll() is None:
                if first is None and (folder/'progress.jsonl').exists() and (folder/'progress.jsonl').stat().st_size:
                    first=time.perf_counter()-started
                time.sleep(.005)
            _,errors=process.communicate(timeout=2)
            assert process.returncode==0,errors.decode()
            packets=[json.loads(line) for line in (folder/'progress.jsonl').read_text().splitlines()]
            epochs=[p['data']['data']['epoch_seconds'] for p in packets if p['phase']=='state']
            assert len(epochs)==3
            results.append({'trial':trial,'first_event_seconds':first,'total_seconds':time.perf_counter()-started,'epoch_seconds':epochs,'visualizations':sum('visualization' in p for p in packets),'ipc_bytes':(folder/'progress.jsonl').stat().st_size})
    return {'environment':sys.version,'path':'train_entry.py → PreparedSession → PreparedLanguageSession','cold_cache_each_trial':True,'runs':results,'epoch_median_seconds':statistics.median(e for r in results for e in r['epoch_seconds'])}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repeats',type=int,default=5)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();result=run(args.repeats)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
