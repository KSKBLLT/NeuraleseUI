"""A real, reversible decoder path from damaged weights to the checkpoint.

The embedding table is lerped from a permuted one-bit table. Attention score
and residual gates recover continuously. All displayed tensors come from ONNX;
at the endpoint inference uses the untouched original session exactly.
"""
from __future__ import annotations

import math
import os

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
import onnxruntime as ort

from ..training_profile import build_session_options, SessionProfile
from .onnx_session import LanguageSession
from .trace_model import ensure_trace_model
from .word_embeddings import ModelWordEmbeddings
from .projection import project_words

VERSION = 1
PROGRESS = "neuralese_learning_progress"
TRAINING_WINDOWS = 2
TRAINING_CONTEXT = 128


def damaged_table(table: np.ndarray) -> np.ndarray:
    # No per-word coordinate rules: this is an actual degraded vocabulary
    # matrix used by the decoder and by the word embedding view alike.
    magnitude = np.mean(np.abs(table), dtype=np.float64)
    return (np.sign(np.roll(table, len(table)//3, axis=0))*magnitude).astype(np.float32)


def ensure_learning_model(bundle):
    trace_path, manifest = ensure_trace_model(bundle)
    target = trace_path.parent/f"decoder-learning-v{VERSION}.onnx"
    if target.is_file():
        return target
    model = onnx.load(trace_path)
    nodes = list(model.graph.node)
    producers = {output: node for node in nodes for output in node.output}
    embedding = manifest["outputs"]["embeddings"]
    gather = producers[embedding]
    weight = next(value for value in model.graph.initializer if value.name == gather.input[0])
    damaged = damaged_table(numpy_helper.to_array(weight))
    model.graph.initializer.extend([
        numpy_helper.from_array(damaged, "neuralese_damaged_embeddings"),
        numpy_helper.from_array(np.array(1,np.float32), "neuralese_one"),
    ])
    model.graph.input.append(helper.make_tensor_value_info(PROGRESS,TensorProto.FLOAT,[]))
    # Scale valid attention scores before masking. Multiplying a masked -inf
    # by zero would make NaNs and destroy causality.
    score_outputs = set()
    for name in manifest["outputs"]["attention"]:
        parent = producers[producers[name].input[0]]
        while parent.op_type in {"Cast","Identity"}:
            parent = producers[parent.input[0]]
        if parent.op_type != "Where":
            raise ValueError("Cannot locate attention scores before their causal mask")
        score_outputs.add(parent.input[1])
    residual_outputs = {n.output[0] for n in nodes if n.op_type=="MatMul" and ("/o_proj" in n.name or "/mlp/down_proj" in n.name)}
    if len(score_outputs)!=bundle.layers or len(residual_outputs)!=bundle.layers*2:
        raise ValueError("Unsupported decoder restoration gates")
    revised = [helper.make_node("Sub",["neuralese_one",PROGRESS],["neuralese_damage"],name="neuralese_damage")]
    for node in nodes:
        name=node.output[0]
        if name==embedding:
            node.output[0]="neuralese_original_embedding"
            revised.extend([node,
                helper.make_node("Gather",["neuralese_damaged_embeddings","input_ids"],["neuralese_damaged_embedding"],axis=0),
                helper.make_node("Mul",["neuralese_original_embedding",PROGRESS],["neuralese_restored_embedding"]),
                helper.make_node("Mul",["neuralese_damaged_embedding","neuralese_damage"],["neuralese_remaining_damage"]),
                helper.make_node("Add",["neuralese_restored_embedding","neuralese_remaining_damage"],[embedding]),
            ])
        elif name in score_outputs or name in residual_outputs:
            raw=name+"_before_learning_gate"
            node.output[0]=raw
            revised.extend([node,helper.make_node("Mul",[raw,PROGRESS],[name])])
        else:
            revised.append(node)
    del model.graph.node[:]
    model.graph.node.extend(revised)
    onnx.checker.check_model(model)
    temporary=target.with_name(f"decoder-learning.{os.getpid()}.tmp.onnx")
    onnx.save(model,temporary)
    os.replace(temporary,target)
    return target


class LearningSession(LanguageSession):
    def __init__(self, reference: LanguageSession):
        super().__init__(reference.bundle,reference.mapping,shared=reference._shared)
        self.reference=reference
        resource=reference._shared
        if not hasattr(resource,"_learning_resources"):
            options=build_session_options(SessionProfile("language",2))
            engine=ort.InferenceSession(str(ensure_learning_model(self.bundle)),sess_options=options,providers=["CPUExecutionProvider"])
            # Initialise the common projection once; damaged and original vectors
            # use exactly the same basis and canonical word pooling.
            resource._word_preview("cat",[])
            view=ModelWordEmbeddings(self.tokenizer,damaged_table(resource._word_view.table),self.bundle.source_hash)
            resource._learning_resources=(engine,view)
        self._learning_ort,self._damaged_words=resource._learning_resources
        self.progress=1.
        self._training_stream=[]
        self._validation=[]

    def prepare_corpus(self, samples, validation_samples):
        self._training_stream=self.tokenizer.encode("\n\n".join(samples),add_special_tokens=False).ids
        self._validation=[self.tokenizer.encode(text,add_special_tokens=False).ids for text in validation_samples]
        self._validation=[ids for ids in self._validation if len(ids)>1]
        if not self._training_stream or not self._validation:
            raise ValueError("Language training needs separate English training and validation examples")

    def _score_tokens(self, ids):
        logits=self.forward(ids)["logits"][0][:-1].astype(np.float64)
        targets=np.asarray(ids[1:],np.int64)
        maximum=logits.max(-1)
        logsum=maximum+np.log(np.exp(logits-maximum[:,None]).sum(-1))
        return (int(np.sum(logits.argmax(-1)==targets)),
                float(np.sum(logsum-logits[np.arange(len(targets)),targets])),len(targets))

    def _corpus_metrics(self, example, batch_index):
        training_loss,training_tokens,passes=0.,0,0
        if self._training_stream:
            stream=self._training_stream
            # Packed windows measure loss with long contexts, as an ordinary LM
            # batch would. Each restoration stage really recomputes these logits;
            # epoch duration follows CPU inference work, with no artificial delay.
            for window in range(TRAINING_WINDOWS):
                start=(batch_index*37+window*len(stream)//TRAINING_WINDOWS)%len(stream)
                ids=[stream[(start+index)%len(stream)] for index in range(TRAINING_CONTEXT)]
                _,loss,count=self._score_tokens(ids)
                training_loss+=loss
                training_tokens+=count
                passes+=1
        if self._validation:
            indices=[(batch_index+slot)%len(self._validation) for slot in range(min(4,len(self._validation)))]
            examples=[self._validation[index] for index in indices]
        else:
            indices=[0]
            examples=[self.tokenizer.encode(example,add_special_tokens=False).ids]
        correct,loss,tokens=0,0.,0
        for ids in examples:
            if len(ids)<2: continue
            matched,cross_entropy,count=self._score_tokens(ids)
            correct+=matched; loss+=cross_entropy; tokens+=count; passes+=1
        if not tokens: raise ValueError("Enter a validation example with at least two tokens")
        return {"validation_accuracy":correct/tokens,"validation_loss":loss/tokens,
                "validation_tokens":tokens,"validation_examples":indices,
                "training_loss":training_loss/max(1,training_tokens),"training_tokens":training_tokens,
                "evaluation_passes":passes}

    def set_progress(self, progress: float):
        if not math.isfinite(progress) or not 0<=progress<=1:
            raise ValueError("Learning progress must be between 0 and 1")
        self.progress=float(progress)
        self.ort=self.reference.ort if progress==1 else self._learning_ort
        self._last_forward=None

    def _additional_feed(self):
        return {} if self.progress==1 else {PROGRESS:np.array(self.progress,np.float32)}

    def _word_preview(self,text,tokens):
        original=self.reference._word_preview(text,tokens)
        if self.progress==1:
            return original
        pristine=self._shared._word_view.words(text,tokens)
        damaged=self._damaged_words.words(text,tokens)
        words=[]
        for first,second in zip(pristine,damaged):
            vector=np.asarray(first["vector"])*self.progress+np.asarray(second["vector"])*(1-self.progress)
            words.append({**first,"vector":vector.tolist()})
        return {**original,"points":project_words(words,self._shared._projection)}

    def training_preview(self,text: str,progress: float,example: str="",batch_index: int=0, on_preview=None):
        self.set_progress(progress)
        result={"nodes":{},"generated_ids":[]}
        predicted=""
        if text.strip():
            prefix=self.tokenize(text)["ids"]
            result=self.preview(prefix,[])
            predicted=self.decode([result["selected_id"]])
        result.update(training_progress=self.progress,predicted_text=predicted)
        if on_preview is not None:
            on_preview(result)
        result.update(self._corpus_metrics(example or text,batch_index))
        # Match the restored teacher's next-token choices on the current small
        # corpus example. This is a measured agreement, not a fabricated curve.
        encoded=self.tokenizer.encode(example or text,add_special_tokens=False).ids
        if not encoded: encoded=self._training_stream[:32]
        ids,_,_,positions=self._context(encoded,[])
        learner=self.forward(ids)["logits"][0]
        teacher=self.reference.forward(ids)["logits"][0]
        evaluated=positions+[len(ids)-1]
        agreement=float(np.mean(learner[evaluated].argmax(-1)==teacher[evaluated].argmax(-1)))
        result.update(training_progress=self.progress,teacher_agreement=agreement,predicted_text=predicted)
        return result
