# Language Nodes with Dummy Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution: inline, authorized by the user; corrections below override the initial task descriptions.

**Goal:** Создать работающий Godot-интерфейс языковых нодов с единым заменяемым backend-контрактом и единственным детерминированным dummy-провайдером.

**Architecture:** Существующие Graph/Connection/материалы/сохранение используются для редактора. Отдельный сервис читает snapshot языкового графа, проверяет его и передаёт dummy-провайдеру; ноды только применяют traces. Числовой Python/ONNX runtime не расширяется и не вызывается.

**Tech Stack:** Godot 4.7.1, GDScript, существующие PackedScene и Loc, JSON-совместимые контракты; Python 3.11 только для существующих docs/release тестов.

**Spec:** `docs/superpowers/specs/2026-10-15-language-nodes-dummy-design.md`


## Утверждённые уточнения перед реализацией

Явный textbox наследует общую базу Input вместе с Input2D; изменение текста запускает автоматический пересчёт и штатные визуальные события inference. Поле копирует native LineEdit, корректно растёт/уменьшается и не обрезает скруглённую рамку.

Последнее уточнение оформления: Dense/Concat/Softmax сохраняют штатный вид и цвет даже в языковом графе. TextInput повторяет Input2D (рамка, жёлтые заголовок/порт, отступы и масштаб; запуск автоматический без Run). Это исключения из общего синего акцента и правил центрирования заголовка ниже.

Последние уточнения пользователя имеют приоритет: размер определяется содержимым с фиксированным шагом сетки, отступы/радиус/масштаб заголовка читаются из Conv2D.tscn; границы плавно следуют за содержимым, заголовки центрированы. Новые названия слитные. Типы text/tokens/vectors/scores различаются в соединениях и проверке графа. NextToken заполняет внутреннюю ширину строками без кнопки «5».

- Основа реализации: свежий `origin/dev` (573dc78), worktree `language-nodes-dummy`. Старый checkout 1485beb отстаёт; утверждение об отсутствии node_defs относится только к нему. Реестр появился в 2b604c3 и используется здесь через tools.node_dev.
- Не создавать sequence_dense, sequence_concat или token_softmax. Переиспользовать существующие `layer`, `concat`, `softmax`; изолировать языковую семантику в adapter/service. Добавить только необходимые портовые/метаданные hooks без новых дублирующих типов и без изменения числового исполнения.
- Шесть новых типов: text_input, tokenizer, embedding, attention_head, token_labels, text_output. Четыре головы параллельны; кнопок/действий свёртки нет.
- Наружу только необходимое: текст ввода; Dense уже имеет количество нейронов; Concat уже имеет слоты. Width у Embedding/AttentionHead отсутствует: размерности приходят из capabilities модели. Words и кнопка числа кандидатов отсутствуют. NextToken по умолчанию показывает пять кандидатов; полный словарь доступен через поиск.
- Единый синий акцент #7f9eff, как семейство элементов Transformer; существующие семантические цвета конфигурационных портов сохраняются. Эталон геометрии, шрифтов, кнопок и отступов — Conv2D и существующие PackedScene.
- Все новые регистрации через node_defs/*.json и генератор. Не править сгенерированные каталоги вручную. Новые preview-only типы не регистрировать как будто у них есть настоящий ONNX handler.
- Сервис и визуализации живут в Godot; ML-весов/зависимостей нет. Demo traces детерминированы и явно помечены. Проверка соединений/форм, сохранение/undo, управление и навигация настоящие.
- Восемь задач ниже исполняются с этими заменами; результаты и точные тесты фиксируются в ledger.

## Global Constraints

- Точка отсчёта: ветка `codex/teacher-block-editor`, HEAD `1485beb`; перед исполнением сверить изменения этой ветки и актуальность путей.
- Единственный провайдер `dummy-v1`; каждый ответ содержит `schema_version=1`, `provider_id`, `is_dummy=true`.
- Никаких Python-процессов, HTTP/WebSocket, ML-библиотек, загрузки весов и новых ONNX-handlers в этом этапе.
- Девять type id и порты из spec; старые числовые type id не меняют поведения.
- Демо D=256, H=4, d_head=64, V=8192; контекст ≤512; генерация ≤32 новых токенов.
- Top-N ∈{5,10,20}, default 5; страница полного словаря ≤50 строк; окно attention ≤16 позиций.
- Для сохранения используются cfg/get_info/map_properties; ephemeral traces/session/request поля не сохраняются.
- Все видимые строки локализованы через существующий Loc (RU/EN/KZ). Визуальная QA — реальные Godot-рендеры.

## Review Focus

- Поздний ответ после изменения графа/Stop/Reset не перезаписывает новый текст — Task 3/7.
- Порядок прихода четырёх голов и случайные graph hints не меняют порядок concat — Task 2/5.
- Словарь на 65536 позиций не создаёт 65536 Controls и не меняет вероятности top-N — Task 6.
- Unicode, пунктуация, одинаковые слова и byte fallback сохраняют границы/обратимость — Task 1/4.
- Старый classifier/Dense и неподдерживаемые смешанные графы ведут себя предсказуемо — Task 2/5/8.

## File Map

Создать в `scripts/language_models/`: `language_contract.gd`, `language_backend.gd`, `dummy_language_backend.gd`, `language_model_service.gd`, `language_graph_adapter.gd`, `language_graph_validator.gd`, `language_graph_controller.gd`, `language_node.gd`, `language_demo_graph.gd`.

Создать в `scripts/language_models/nodes/` и `scenes/language_models/`: девять одноимённых `<type_id>.gd` / `<type_id>.tscn` из spec. Текстовые Dense/Concat/Softmax/Labels наследуют существующие сцены визуально, но получают отдельные скрипты и server_typename; не наследовать числовые побочные эффекты вслепую.

Создать `scripts/language_models/views/{token_strip,embedding_plot,attention_heatmap,token_candidates}.gd`, `scenes/language_models/vocabulary_dialog.tscn`, `scripts/language_models/views/vocabulary_dialog.gd`, `resources/language_model_demo.json`.

Изменить интеграционные точки: `project.godot`, `scripts/graph_manager.gd`, `scripts/glob.gd`, `scripts/node_palette.gd`, `scripts/graph_script_parser.gd`, `scripts/run_manager.gd` (только guard от передачи языкового графа в числовой runtime), `tests/godot/run_all.sh`, `tests/jasondocs/test_public_docs_content.py`. Добавить JasonDocs/иконки для девяти нодов и обновить `resources/node_info_catalog.json` существующим CLI. Изменение старых scene/scripts допустимо только если выявлен необходимый общий hook, с отдельным regression test.

## Task 1: Контракт и детерминированный backend

**Files:** contract/backend/dummy scripts и demo JSON из File Map; `tests/godot/test_language_backend.gd`.

**Interfaces:** `LanguageBackend extends RefCounted`: signal `response_ready(response: Dictionary)`; `submit(request: Dictionary) -> void`; `dispose() -> void`. Все вызовы завершаются через signal, включая dummy; submit не возвращает результат синхронно. `LanguageContract.make_request(method: StringName, params: Dictionary, request_id: int, session_id: String, graph_revision: int) -> Dictionary`; `validate_response(response: Dictionary) -> Array[String]`.

`DummyLanguageBackend._init(options: Dictionary = {})`: допускает `vocab_size` 8192 по умолчанию и 65536 для stress-теста; vocabulary_id включает размер, provider_id всегда `dummy-v1`. Production-фабрика использует пустые options. Ответы run_step несут полный scores одной позиции и `{id,piece}` для лучших 20/выбранного токена. Проверка envelope и payload отклоняет NaN/Inf, отрицательные вероятности, неверную длину и сумму вероятностей вне допуска 1e-5.

Методы params/result: capabilities → размеры/поддерживаемые ops/training=dummy/export=false; open_session({graph}) → {session_id}; tokenize({text,vocabulary_id}) → {tokens,text}; run_step({graph,prefix_ids,generated_ids,position}) → snapshot из spec; inspect({node_id,position,query_start,query_count,key_start,key_count}) → bounded trace; vocabulary_page({query,offset,limit}) → {entries,total,offset}; train({example_count}) → progress/completed events; cancel({target_request_id}) → {cancelled}; close_session({}) → {closed}. Envelope сигналов обучения дополнительно содержит `event` из started/progress/completed, остальные ответы — result. Неизвестный метод возвращает error.code=`unsupported_method`.

- [ ] Написать тесты: roundtrip JSON; обязательный is_dummy; одинаковый вход/seed даёт одинаковый результат; несколько сессий независимы; неизвестный метод/ID не даёт успех; cancel/close идемпотентны; input tokenization roundtrip для английского, русского, казахского, emoji и пробелов.
- [ ] Запустить новый тест и увидеть FAIL из-за отсутствующего контракта.
- [ ] Реализовать интерфейс и dummy. Демословарь: 8192 ID, фиксированные слова/пунктуация/спецтокены и 256 byte токенов; прочие ID синтетические. Фикстура следующего текста — ` mat.` и EOS; это демонстрация, не ответ на произвольный вопрос. Размеры и causal-маски согласованы с запросом. Первое доступное значение attention в строке 0 равно 1; будущие ключи 0; строки нормированы. Не выдавать случайные карты из views.
- [ ] Проверить PASS; тест дополнительно проверяет length(scores)=8192, sum(probabilities)≈1, head shapes T×64 и явно dummy-результат train без записи весов.
- [ ] Зафиксировать файлы этой задачи после принятого пользователем старта реализации.

## Task 2: Snapshot и валидация реального графа

**Files:** graph_adapter/validator и `tests/godot/test_language_graph.gd`.

**Interfaces:** `LanguageGraphAdapter.collect(source: Graph) -> Dictionary` возвращает spec graph snapshot; `LanguageGraphValidator.validate(graph: Dictionary, capabilities: Dictionary, token_count: int = -1) -> Dictionary` возвращает `{ok,errors,order,shapes}`; errors — `{code,message,node_id}`; shapes — map node_id → `{input_shape,output_shape}`. До токенизации T обозначается строкой `"T"`; после неё controller передаёт фактический token_count. Registry op names равны type id; Concat сортируется по именам портов, не head arrival order.

- [ ] Написать тесты полного 4-голового графа: [T,256] → четыре [T,64] → [T,256] → [T,256] → [T,8192] → [8192]. Оба sink получают тот же шаг.
- [ ] Добавить отрицательные тесты: цикл; лишний/отсутствующий вход; два источника; numeric Input1D в языковом графе; разные словари/позиции; неравные T; повторённый head_index; пропущенная голова; неправильный V перед Softmax. Перестановка nodes/edges в Dictionary не меняет concat.
- [ ] Убедиться, что тесты FAIL, затем реализовать сборку без вызова `graphs.get_syntax_tree()`/`Graph._io()` и чистую проверку форм.
- [ ] Проверить PASS; ошибки локализуются по code, в ошибке всегда известен виновный node_id. Зафиксировать задачу.

## Task 3: Сервис, контроллер и защита от устаревших ответов

**Files:** service/controller/language_node, `project.godot` (autoload `language_models`), `tests/godot/test_language_controller.gd`.

**Interfaces:** `LanguageModelService extends Node`: signal `response_ready(response: Dictionary)`; `set_backend(backend: LanguageBackend) -> void`; `request(method: StringName, params: Dictionary, session_id: String, graph_revision: int) -> int`; `cancel(request_id: int) -> void`; `close_session(session_id: String) -> void`. Сервис добавляет/проверяет envelope и выдаёт монотонные request_id. Контроллер: `start(source: Graph)`, `step()`, `continue_generation()`, `stop()`, `reset()`, `invalidate_graph()` — все `-> void`; signals `state_changed(state: StringName)`, `snapshot_ready(snapshot: Dictionary)`, `failed(error: Dictionary)`.

Общий контракт нода (методы без конфликтов с Axon llm_config): `get_language_op() -> StringName`, `get_language_config() -> Dictionary`, `apply_language_trace(trace: Dictionary) -> void`, `clear_language_trace() -> void`. Специализации существующих сцен реализуют тот же протокол через composition/helper; общий `LanguageNode` используется новыми простыми сценами.

- [ ] Fake-backend в тесте сохраняет запросы и отдаёт ответы в управляемом порядке. Проверить один in-flight step, точный сброс, Stop, EOS и лимиты 32/512.
- [ ] Проверить: response A после изменения текста/связи/удаления нода/загрузки проекта игнорируется; response B текущего revision применяется ровно один раз; close/dispose очищают callbacks. Две сессии не смешиваются.
- [ ] Запустить FAIL, реализовать state machine и deferred dummy-ответы. Один UI-кадр между продолжениями. Сигналы node config/connection lifecycle инвалидируют сессию; если общего сигнала нет, добавить только сигнал в base_graph/connection с отдельной проверкой старого поведения.
- [ ] Проверить PASS и отсутствие вызовов `nn`, Python/OS.execute, HTTP/WebSocket. Применение snapshot не меняет cfg/revision и не создаёт undo; повторный snapshot не отменяет текущую сессию сам. Зафиксировать задачу.

## Task 4: Текст, токены и Embedding PCA-view

**Files:** text_input/tokenizer/embedding scenes/scripts; token_strip/embedding_plot; `tests/godot/test_language_input_views.gd`.

**Interfaces:** views `set_preview(preview: Dictionary) -> void`; `clear_preview() -> void`; `EmbeddingPlot` signal `token_selected(position: int)`. Токеновая позиция, а не строка слова, связывает выделение между views. Координаты/векторы приходят из backend snapshot; backend preview содержит `basis_id`, `points` и выбранный vector slice.

- [ ] Тесты: подстроки по start/end; повтор слова имеет отдельную позицию; пустой текст; сохранение многострочного текста через cfg; выбор точки выбирает правильный токен; одинаковый ID сохраняет координаты при добавлении текста.
- [ ] Проверить FAIL, создать настоящие сцены на BaseGraph, существующих input/button материалах и Loc. PCA-точки рисовать одним custom Control, не отдельной карточкой на каждый вектор. Показывать входные токены; не применять output top-N к Embedding. Дополнительные подписи по hover/выбору, zoom/Expand для длинного текста.
- [ ] Проверить PASS и empty/loading/error/demo состояния. Зафиксировать задачу.

## Task 5: Отдельные головы, Склейка, Dense и Softmax

**Files:** attention_head/sequence_concat/sequence_dense/token_softmax scenes/scripts; attention_heatmap; `tests/godot/test_language_attention_views.gd`.

**Interfaces:** type ids/порты из spec. head config `{head_index:int,head_count:4,model_width:256,head_width:64,causal:true}`; concat config `{head_count:4}`; dense config `{neuron_count:int}`; softmax config `{position:-1}`. `AttentionHeatmap.set_preview(preview: Dictionary)`, `set_word_mode(enabled: bool)`, `set_window(start: int, count: int)` — `-> void`.

- [ ] Тесты на четыре разные карты с одинаковой разметкой; causal нули и маску; word aggregation; окна не теряют абсолютные позиции; все подписи совпадают с tokenizer. Для dummy первые token-level ячейки каждой головы равны 1.
- [ ] Тесты Concat после переподключения и save/load сохраняют head_0…head_3; Dense создаёт ограниченное число кружков при 8192 нейронах; token Softmax проверяет V и выбранную позицию. Старые сцены layer/concat/softmax остаются числовыми.
- [ ] Получить FAIL, затем реализовать специализации сцен с отдельными scripts. Для Dense можно наследовать NeuronLayer ради экспортируемых свойств и `_apply_grouping()`, но переопределить `_config_field`, `_just_connected`, `re_upd` и прочие числовые callbacks: trace не должен вызывать push_1d/ONNX path или менять cfg. Для concat переиспользовать frame/slot-компоненты, но именовать слоты явно и не наследовать случайные hints. До ответа сервиса карты пустые.
- [ ] Проверить PASS. Выделение/камеру/drag внутри графа не перехватывают интерактивные области heatmap. Зафиксировать задачу.

## Task 6: Выход с большим словарём

**Files:** token_labels/text_output scenes/scripts; token_candidates/vocabulary_dialog; `tests/godot/test_language_output_views.gd`.

**Interfaces:** `TokenCandidates.set_distribution(scores: Array, selected_token_id: int, vocabulary_id: String) -> void`; `set_visible_count(count: int) -> void`; signal `lookup_requested(query: String, offset: int, limit: int)`. `VocabularyDialog.set_page(page: Dictionary) -> void`. Сортировка top-N: убывание вероятности, при равенстве меньший ID. «Остальные»=sum всех скрытых вероятностей.

- [ ] Тесты с V=8192 и V=65536: всего N строк кандидатов и ≤50 строк окна словаря; поиск последнего ID работает; top-N не перенормирует вероятности и не меняет next_token_id. Проверять child count, не только высоту/прокрутку.
- [ ] Проверить selected_token_id при смене рангов; одинаковые piece с разными ID; предел страницы; пустой поиск; повторное открытие диалога без накопления Controls. TextOutput показывает prefix отдельно и decoded generated text без вставки лишних пробелов/вывода EOS.
- [ ] Получить FAIL; реализовать специализацию реального classifier frame/row pattern. При наследовании OutputGraph переопределить `_unit_just_added`, `_request_save`, `_config_field` и preview-удаление строк: унаследованное сохранение названий в cfg и learner.notify_update не выполняется при обновлении preview. Не вызывать `OutputGraph.set_names()` с полным словарём, не сериализовать все label_names. TokenLabels — sink без output-порта. TextOutput получает соседнюю ветвь того же scores snapshot, не запускает второй sampler.
- [ ] Проверить PASS; режим 5/10/20 изменяет только отображение. Зафиксировать задачу.

## Task 7: Включение в существующий редактор и сохранение

**Files:** graph_manager/glob/node_palette/graph_script_parser; demo_graph; `tests/godot/test_language_editor_integration.gd`.

**Interfaces:** `LanguageDemoGraph.create(manager: Node, origin: Vector2) -> Dictionary` создаёт эталонный graph и возвращает `{source,nodes}`. `graph_types` и `glob.llm_name_mapping` получают девять согласованных записей; parser `_choose_origins()` распознаёт TextInputNode.

- [ ] Тесты палитры/поиска/drag для всех девяти type id и fallback icons; Axon summary не падает на новых типах; source определяется как TextInput. При одиночном source палитра скрывает/разрешает все input families согласованно с multi_input. `get_alt_nodes()` не предлагает менять числовой Input/Dense на TextInput с сохранением несовместимых проводов; не добавлять text_input в общий список замен вслепую.
- [ ] Проверить создание graph по настоящим портам, старт/шаг и отображение traces в каждом ноде; изменение cfg/связей инвалидирует старый request. Save/load через существующие Graph APIs сохраняет type/config/позиции/связи/порядок слотов без session/traces/8192 labels. Undo/redo удаления и переподключения не возвращает устаревшие traces.
- [ ] Получить FAIL, интегрировать без новой системы реестра/генератора. У новых классов `server_typename` не маскируется под NeuronLayer/ClassifierNode, поэтому старый run_manager не отправляет их в numeric inference. Для несовместимого вызова numeric run дать локальное понятное сообщение.
- [ ] Проверить PASS и открыть прежний числовой граф с прежними типами. Зафиксировать задачу.

## Task 8: Документация, настоящие рендеры и полный прогон

**Files:** `JasonDocs/<new_type>/node.json`, `node_icons/Icon<Type>.png`, runtime catalog; `tests/jasondocs/test_public_docs_content.py`; `tests/godot/run_all.sh`; `tests/godot/render_language_nodes.gd`; `docs/language-nodes-dummy-qa.md`.

- [ ] Добавить каждый новый `test_language_*.gd` в marker-based runner с точным `PASS <имя>`; код выхода теста должен быть ненулевой при assertion failure. Новый файл без записи в TESTS не считается проверкой.
- [ ] Через `python -m tools.jasondocs sync` получить generated metadata, затем написать простые RU/EN/KZ descriptions/settings/examples и обновить public-node contract. `python -m tools.jasondocs runtime`, затем `python -m tools.jasondocs validate`.
- [ ] Рендер-сценарий использует те же сцены, demo_graph и dummy backend. Делает реальные PNG в явную QA-папку; ничего не сохраняет в пользовательский проект и не вызывает реальные runtime/update/network пути. Проверить 1280×720 и 1440×900, zoom 0.75/1/1.5, RU/EN/KZ; 5 и 128 входных токенов; top-5 и поиск по 65536. Все 512 позиций доступны через окна, даже если весь контекст не помещается в одном кадре.
- [ ] Открыть полученные PNG через view_image; проверить читаемость слов, causal маску, кружки Dense, компактность Output Labels, отсутствие обрезания/перекрытия соединений. Проверить мышью hit testing, Step/Continue/Stop/Reset и expand/search в настоящем приложении.
- [ ] Выполнить `python -m pytest tests/jasondocs tests/release tests/integration -q`, `GODOT_BIN=... bash tests/godot/run_all.sh`, `python -m tools.jasondocs validate`, `git diff --check`. Не повторять тяжёлые прогоны без новых изменений/ошибок. Записать точные результаты/артефакты и ограничения в QA doc; только после этого заявлять готовность dummy UI.

## Проверка исходного состояния, 15 октября 2026

- `tools.jasondocs scan`: 21 активный тип нода.
- `python -m pytest tests/jasondocs -q`: 5 passed.
- `python -m tools.jasondocs validate`: passed.
- Godot `4.7.1.stable.steam.a13da4feb`, существующий `tests/godot/run_all.sh`: все 18 marker checks passed. Первый импорт выдавал предупреждения/ошибки загрузки существующих .scn и editor placeholder; успешный marker runner не означает отсутствие всех import diagnostics.
- Продуктовый код в рамках этой работы не менялся. Новые тесты/контракты пока существуют только как пункты плана и не объявляются выполненными.
