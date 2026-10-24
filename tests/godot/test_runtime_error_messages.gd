extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var messages = load("res://scripts/runtime_error_messages.gd")
	var shape_error := {
		"code": "training_output_count_mismatch",
		"details": {"dataset": "eco_ai", "expected": 4, "actual": 3},
		"technical_message": "onnxruntime::training::api::Module::TrainStep C:\\runtime\\module.cc:632",
	}
	var ru: String = messages.for_packet(shape_error, "training", "ru")
	_expect("eco_ai" in ru and "4" in ru and "3" in ru, "Russian training error must explain the expected and actual output counts")
	_expect(not "onnxruntime" in ru and not "module.cc" in ru, "Technical ONNX details must not leak into the Russian toast")
	var en: String = messages.for_packet(shape_error, "training", "en")
	_expect("eco_ai" in en and "4" in en and "3" in en, "English training error must explain the expected and actual output counts")
	var kz: String = messages.for_packet(shape_error, "training", "kz")
	_expect("eco_ai" in kz and "4" in kz and "3" in kz, "Kazakh training error must explain the expected and actual output counts")

	var generic := {
		"code": "training_failed",
		"technical_message": "Traceback: secret path C:\\Users\\student\\runtime.py",
	}
	var generic_ru: String = messages.for_packet(generic, "training", "ru")
	_expect("Не удалось начать обучение" in generic_ru, "Unknown training errors must have an actionable Russian fallback")
	_expect(not "Traceback" in generic_ru and not "C:\\Users" in generic_ru, "Raw tracebacks and paths must never be shown in a toast")

	var inference := {
		"code": "inference_input_shape_mismatch",
		"details": {"expected": "28x28", "actual": 12},
		"technical_message": "InvalidArgument from onnxruntime",
	}
	var inference_ru: String = messages.for_packet(inference, "inference", "ru")
	_expect("28x28" in inference_ru and "12" in inference_ru, "Inference errors must explain the required model input")
	_expect(not "InvalidArgument" in inference_ru, "Inference diagnostics must stay out of the toast")
	var missing_graph_ru: String = messages.for_code("inference_graph_missing", {}, "ru")
	_expect("Выберите модель" in missing_graph_ru, "Starting inference without a model must tell the user what to select")
	var invalid_graph_ru: String = messages.for_code("training_graph_invalid", {}, "ru")
	_expect("подсвеченные" in invalid_graph_ru, "Invalid training graphs must point the user to the fields that need attention")

	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_runtime_error_messages")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
