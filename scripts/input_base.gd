extends Graph
class_name InputGraph
## Shared input identity and the existing visual inference lifecycle.
## Numeric requests already publish these events through run_manager.

func begin_input_visual(request_id: int) -> void:
	nn.inference_dispatched.emit(self,request_id)

func finish_input_visual(request_id: int) -> void:
	nn.inference_finished.emit(self,request_id)
