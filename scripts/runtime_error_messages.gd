extends RefCounted


static func for_packet(error_data: Variant, operation: String, language: String) -> String:
	var packet: Dictionary = error_data if error_data is Dictionary else {}
	return for_code(str(packet.get("code", operation + "_failed")), packet.get("details", {}), language)


static func for_code(code: String, details: Dictionary = {}, language: String = "en") -> String:
	var dataset := str(details.get("dataset", ""))
	var expected := str(details.get("expected", "?"))
	var actual := str(details.get("actual", "?"))
	match language:
		"ru":
			match code:
				"language_demo_only":
					return "Текстовые модели пока работают в деморежиме. Обучение и экспорт ещё недоступны."
				"training_output_count_mismatch":
					return "Датасету «%s» нужно %s выхода модели, а сейчас модель выдаёт %s. Измените размер выхода модели на %s." % [dataset, expected, actual, expected]
				"training_input_shape_mismatch":
					return "Форма входа не подходит датасету «%s»: модель ожидает %s, а датасет передаёт %s. Проверьте размер узла ввода." % [dataset, expected, actual]
				"training_target_shape_mismatch":
					return "Форма ответа датасета «%s» не совпадает с выходом модели: нужна %s, сейчас %s. Проверьте выход модели и ответы датасета." % [dataset, expected, actual]
				"training_sample_count_mismatch":
					return "В датасете «%s» разное количество примеров и ответов. Исправьте строки датасета и попробуйте снова." % dataset
				"training_classification_shape_invalid", "training_class_indices_invalid":
					return "Ответы датасета «%s» имеют неверный формат для классификации. Проверьте классы и метки ответов." % dataset
				"training_graph_io_invalid":
					return "Для обучения нужна модель с одним входом и одним выходом. Проверьте соединения графа."
				"training_graph_invalid":
					return "Граф обучения не готов. Заполните подсвеченные поля и проверьте соединения узлов."
				"training_no_trainable_parameters":
					return "В модели нет обучаемых слоёв. Добавьте обучаемый слой между входом и выходом."
				"dataset_not_selected":
					return "Выберите датасет перед началом обучения."
				"dataset_unavailable":
					return "Датасет «%s» недоступен локально. Обновите локальный runtime или выберите другой датасет." % dataset
				"dataset_empty", "dataset_no_trainable_rows":
					return "В датасете «%s» нет данных для обучения. Добавьте корректные строки и попробуйте снова." % dataset
				"model_not_trained":
					return "Для этой модели ещё нет результатов обучения. Сначала обучите модель."
				"inference_graph_missing":
					return "Выберите модель перед запуском."
				"inference_graph_invalid":
					return "Модель не готова к запуску. Заполните подсвеченные поля и проверьте соединения узлов."
				"inference_input_shape_mismatch":
					return "Модель ожидает вход %s, но получила %s значений. Проверьте входной узел и источник данных." % [expected, actual]
				"runtime_unavailable":
					return "Локальный модуль ИИ не готов. Перезапустите Neuralese; если ошибка повторится, обновите приложение."
				"runtime_component_missing":
					return "Не найден компонент локального ИИ. Обновите или переустановите Neuralese."
				"runtime_data_write_failed":
					return "Не удалось подготовить данные для локального ИИ. Проверьте свободное место и права на папку приложения."
				"runtime_start_failed":
					return "Не удалось запустить локальный модуль ИИ. Перезапустите Neuralese или переустановите приложение."
				"inference_failed":
					return "Не удалось запустить модель. Проверьте входные данные и соединения графа."
				_:
					return "Не удалось начать обучение. Проверьте датасет, вход и выход модели."
		"kz":
			match code:
				"language_demo_only":
					return "Мәтіндік модельдер әзірше демо режимде жұмыс істейді. Оқыту және экспорттау әлі қолжетімсіз."
				"training_output_count_mismatch":
					return "«%s» деректер жиынына модельдің %s шығысы қажет, ал модель қазір %s мән береді. Модель шығысын %s етіп өзгертіңіз." % [dataset, expected, actual, expected]
				"training_input_shape_mismatch":
					return "Модель кірісі «%s» деректер жиынына сәйкес емес: %s қажет, %s берілді. Кіріс түйінінің өлшемін тексеріңіз." % [dataset, expected, actual]
				"training_target_shape_mismatch":
					return "«%s» деректер жиынының жауап пішіні модель шығысымен сәйкес емес: %s қажет, қазір %s." % [dataset, expected, actual]
				"model_not_trained":
					return "Бұл модель әлі оқытылмаған. Алдымен модельді оқытыңыз."
				"inference_graph_missing":
					return "Іске қосу алдында модельді таңдаңыз."
				"training_graph_invalid", "inference_graph_invalid":
					return "Граф дайын емес. Белгіленген өрістерді толтырып, түйін байланыстарын тексеріңіз."
				"inference_input_shape_mismatch":
					return "Модель %s кірісін күтеді, бірақ %s мән алды. Кіріс түйінін және дерек көзін тексеріңіз." % [expected, actual]
				"runtime_unavailable", "runtime_component_missing", "runtime_start_failed":
					return "Жергілікті AI модулін іске қосу мүмкін болмады. Neuralese қолданбасын қайта іске қосыңыз немесе жаңартыңыз."
				"inference_failed":
					return "Модельді іске қосу мүмкін болмады. Кіріс деректерін және граф байланыстарын тексеріңіз."
				_:
					return "Оқытуды бастау мүмкін болмады. Деректер жиынын және модель кірісі мен шығысын тексеріңіз."
		_:
			match code:
				"language_demo_only":
					return "Text models currently run in demo mode. Training and export are not available yet."
				"training_output_count_mismatch":
					return "Dataset “%s” needs %s model outputs, but the model currently returns %s. Change the model output size to %s." % [dataset, expected, actual, expected]
				"training_input_shape_mismatch":
					return "The model input does not match dataset “%s”: expected %s, received %s. Check the input node size." % [dataset, expected, actual]
				"training_target_shape_mismatch":
					return "Dataset “%s” targets do not match the model output: expected %s, received %s. Check the model output and dataset targets." % [dataset, expected, actual]
				"training_sample_count_mismatch":
					return "Dataset “%s” has a different number of samples and targets. Fix its rows and try again." % dataset
				"training_classification_shape_invalid", "training_class_indices_invalid":
					return "Dataset “%s” has invalid classification targets. Check its classes and answer labels." % dataset
				"training_graph_io_invalid":
					return "Training needs a model with one input and one output. Check the graph connections."
				"training_graph_invalid":
					return "The training graph is not ready. Fill in the highlighted fields and check its connections."
				"training_no_trainable_parameters":
					return "The model has no trainable layers. Add a trainable layer between its input and output."
				"dataset_not_selected":
					return "Select a dataset before starting training."
				"dataset_unavailable":
					return "Dataset “%s” is not available locally. Update the local runtime or choose another dataset." % dataset
				"dataset_empty", "dataset_no_trainable_rows":
					return "Dataset “%s” has no usable training data. Add valid rows and try again." % dataset
				"model_not_trained":
					return "This model has not been trained yet. Train it before running it."
				"inference_graph_missing":
					return "Select a model before running it."
				"inference_graph_invalid":
					return "The model is not ready to run. Fill in the highlighted fields and check its connections."
				"inference_input_shape_mismatch":
					return "The model expects input %s but received %s values. Check the input node and data source." % [expected, actual]
				"runtime_unavailable":
					return "The local AI runtime is not ready. Restart Neuralese; if this continues, update the app."
				"runtime_component_missing":
					return "A local AI component is missing. Update or reinstall Neuralese."
				"runtime_data_write_failed":
					return "Neuralese could not prepare local AI data. Check free disk space and app folder permissions."
				"runtime_start_failed":
					return "The local AI runtime could not start. Restart Neuralese or reinstall the app."
				"inference_failed":
					return "The model could not run. Check its input data and graph connections."
				_:
					return "Training could not start. Check the dataset and the model input and output."
