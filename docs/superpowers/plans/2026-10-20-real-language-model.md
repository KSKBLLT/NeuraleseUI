# Real language model and Neuralese nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Пользователь поручил выполнить план сразу; выполнение в текущей сессии.

**Goal:** Подключить clean1000 к языковым нодам, заменить Авторегрессию, точно ограничить обновление по связям и проверить всё на настоящей модели и в живом UI.

**Architecture:** Godot LanguageBackend → резидентный Python worker → CPU ONNX + tokenizer checkpoint. Отдельный экспорт открывает внутренние тензоры; калиброванные профили и карта нод обеспечивают приблизительную адаптацию без обучения с нуля. UI копирует существующие компоненты Neuralese.

**Tech Stack:** Godot 4.7.1, GDScript, Python 3.11, NumPy 1.26.4, ONNX 1.14.1, ORT 1.19.2, tokenizers 0.22.2; PyTorch/Transformers только для подготовки и эталонных проверок.

**Spec:** `docs/superpowers/specs/2026-10-20-real-language-model-design.md`.

## Global Constraints

- База — `4f590d8a9d2547e49f05844177d22a36d803578e` ветки `robot-integration`.
- Правило UI: **копируй, переиспользуй, проверяй, делай аккуратно**.
- Словарь 20 002, hidden size 256, 4 query heads / 2 KV heads, контекст 512; исходные файлы checkpoint не изменять.
- При 8–12 визуальных этапах исходные веса сохраняются побитово. Качество сжатых профилей проверять отдельно.
- Настоящие attention, embeddings и probabilities происходят из используемой модели; dummy не является production fallback.
- Embedding рисует слова. Оси проекции стабильны между редактированиями текста.
- Авторегрессия: две короткие подписи «Смело»/«Выбор», два штатных ползунка, поле текста, «Шаг», единственный верхний входной порт; никаких нижних/выходных портов.
- Новый preview по топологии запускается только от принятого добавления связи между любыми языковыми нодами. Обычное изменение графа такого preview не запускает.
- Generated files изменяются только генератором из `node_defs/*.json`.
- Не добавлять второй конфликтующий дистрибутив ORT поверх имеющегося `onnxruntime-training-cpu`.

## Review Focus

- Кириллица, казахские буквы и emoji: offsets и байтовые фрагменты не портят текст и не дублируют веса символов — задачи 2, 4, 5.
- Два быстрых клика/отмена/новая сессия: один token ID на подтверждённый шаг, поздний ответ не меняет новый текст — задачи 3, 5.
- Неполная сеть, параллельные головы, одинаковые graph ID после загрузки: стабильное сопоставление реальных слоёв и полезный preview — задачи 1, 6.
- Два визуальных слоя и плохое качество сжатия: отчёт с фактическим профилем и честное сопоставление, отсутствие скрытой рандомизации весов — задача 1.
- Загрузка, undo/redo, offscreen-ноды, перемещение и посторонние ветки: строгая матрица причин обновления — задачи 6, 8.
- Учебная тренировка: остановка, удаление/разрыв цепочки, повторный запуск, смена датасета/сети и настоящая ошибка checkpoint не оставляют UI в Stop и не подменяются успехом — задача 9.

---

## Структура файлов

| Область | Файлы и ответственность |
|---|---|
| Подготовка | `tools/language_models/{prepare_bundle,export_traces,calibrate_profiles,build_projection}.py`: bundle, выходы ONNX, исследование глубины, матрица проекции |
| Python runtime | `local_runtime/neuralese_local/language/{model_bundle,onnx_session,graph_mapping,sampling,word_embeddings,projection,worker}.py`: независимые части реального инференса |
| Godot backend | `scripts/language_models/onnx_language_backend.gd`, `local_language_worker.gd`; существующие `language_contract.gd`, `language_model_service.gd`, `language_graph_controller.gd` |
| Визуализации | `scripts/language_models/views/{embedding_plot,attention_heatmap,token_strip}.gd`; сохранение существующего оформления |
| Авторегрессия | заменить `scenes/language_models/autoregression.tscn`; удалить `autoregression_node.gd` и создать `autoregression.gd`; `node_defs/autoregression.json` |
| Тесты | `tests/local_runtime/test_language_*.py`, `tests/godot/test_language_*.gd/.tscn`, регистрация в `tests/godot/run_all.sh` |
| Артефакты | `docs/assets/real-language-model/`, `docs/language-node-verification.md`, штатные `node_icons/{en,ru,kz}/` и JasonDocs |

### Task 1: Bundle, исследование профилей и сопоставление графа

**Files:** создать инструменты подготовки и `model_bundle.py`, `graph_mapping.py`; тесты `tests/local_runtime/test_language_bundle.py`, `test_language_profiles.py`.

**Interfaces:** `load_bundle(path: Path) -> ModelBundle`; `resolve_graph(graph: dict, profiles: dict) -> dict` с `node_mapping`, `requested_depth`, `effective_depth`, `profile_id`; manifest хранит хеши, размеры, tokenizer и trace outputs.

- [ ] Записать падающие тесты: bundle принимает директорию комплекта/директорию модели; повреждённый manifest и несовместимые размеры отклоняются; 8–12 этапов сохраняют исходные веса; параллельные головы — один этап; два последовательных этапа — два запроса глубины.
- [ ] Запустить `python -m pytest tests/local_runtime/test_language_bundle.py tests/local_runtime/test_language_profiles.py -v`; подтвердить отсутствие реализации.
- [ ] Реализовать разрешение путей из настройки/переменной окружения и packaged assets. Подготовка пишет отдельный cache, не изменяет комплект и не коммитит веса в git.
- [ ] На фиксированных раздельных calibration/held-out наборах сравнить BI-pruning, соседний LERP/SLERP и identity для глубин 2/4/6. Сохранить NLL, KL, top-1, задачи, время и размер; применять критерии из spec. Околонативные 8–12 всегда identity. При провале сжатия использовать сохранённый качественный профиль с явной фактической глубиной.
- [ ] Добавить проверку: cache key включает source hash + mapping + algorithm version; изменение расположения нод его не меняет. Прогнать тесты и зафиксировать задачу отдельным коммитом.

### Task 2: Настоящий ONNX forward, tokenizer и тензоры

**Files:** `export_traces.py`, `onnx_session.py`, `sampling.py`, `test_language_onnx.py`, `test_language_sampling.py`.

**Interfaces:** `LanguageSession(bundle, mapping, seed=42)`; `tokenize(text: str) -> dict`; `preview(prefix_ids: list[int], trace_nodes: list[str]) -> dict`; `step(prefix_ids: list[int], generated_ids: list[int], temperature: float, top_k: int) -> dict`; `inspect(node_id: str, start: int, limit: int) -> dict`.

- [ ] Сначала тесты на настоящем clean1000: logits совпадают с исходным ONNX при `rtol=atol=4e-4`, greedy IDs совпадают; prefill и cached decode эквивалентны; attention конечен, сумма строк ≈1, будущие позиции равны нулю, правильное GQA 4/2.
- [ ] Отдельно тестировать temperature=0, top-k=1/5/20, заданный seed, EOS, переполнение 512, пустой текст и независимость двух сессий.
- [ ] Выполнить `python -m pytest tests/local_runtime/test_language_onnx.py tests/local_runtime/test_language_sampling.py -v`, подтвердить красную фазу.
- [ ] Опубликовать именованные промежуточные выходы копии ONNX без изменения весов; сохранить их карту. Использовать tokenizer.json checkpoint, ChatML только в модельном контексте, токены пользователя отдельно для отображения. Сэмплинг только по числовым logits.
- [ ] Повторить тесты с реальной моделью, записать результаты и отдельный коммит.

### Task 3: Резидентный worker и Godot backend

**Files:** `worker.py`, `local_language_worker.gd`, `onnx_language_backend.gd`; изменить сервис/контракт, runtime requirements/lock и сборку payload; `test_language_worker.py`, `test_language_real_backend.gd`.

**Interfaces:** существующий `submit(request: Dictionary)`/`response_ready`; методы протокола из spec плюс `preview_node`; `dispose()` останавливает процесс. Envelope всегда сохраняет ID запроса, сессию и ревизию.

- [ ] Написать падающие тесты round-trip capabilities→open→tokenize→preview→step→inspect→close; два запроса не перезаписывают друг друга; отменённый ответ и ответ чужой сессии не применяются; отсутствующий bundle выдаёт понятную ошибку без dummy fallback.
- [ ] Запустить `python -m pytest tests/local_runtime/test_language_worker.py -v` и Godot-тест отдельным headless-запуском.
- [ ] Реализовать worker по шаблону существующего resident local runtime: атомарные файлы, очередь, прогретая модель, лимиты памяти/очистка KV, наблюдение за родительским процессом. Godot делает только неблокирующий submit/poll и обработку ошибок.
- [ ] Production service выбирает реальный backend; имеющиеся unit-тесты явно инжектируют dummy. Добавить tokenizers/Jinja2 в runtime и пересоздать lock штатным процессом, не устанавливать конфликтующий ORT.
- [ ] Прогнать тесты и проверить, что UI остаётся отзывчивым во время первого запуска; отдельный коммит.

### Task 4: Эмбеддинги слов и стабильная проекция

**Files:** `word_embeddings.py`, `projection.py`, `build_projection.py`; изменить `views/embedding_plot.gd`; `test_language_word_embeddings.py`, `test_language_projection.py`, проверки `test_language_views.gd`.

**Interfaces:** `pool_words(text: str, tokens: list[dict], embeddings: ndarray) -> list[dict]` с `text/start/end/positions/vector`; `project_words(words: list[dict], projection: dict) -> list[dict]` возвращает координаты и те же настоящие векторы.

- [ ] Написать тесты мама/папа/король/королева, казахских букв, emoji, нескольких byte-токенов на символ, одинакового слова в разных позициях; проверять pooled vector, а не первый token vector.
- [ ] Проверить стабильность координат при добавлении других слов. Для anchor-примера: cosine направлений ≥0.9, отношение длин 0.8–1.25 и ненулевая длина; отдельно сохранить ошибку соседства и результаты held-out аналогий, не объявляя их заранее успешными.
- [ ] Выполнить красный `pytest`, затем pooling до проекции и фиксированную регуляризованную линейную матрицу. Anchor-корпус, настройки и метрики сохраняются. Не добавлять подстановку координат по строкам слов.
- [ ] Удалить повторный pooling координат в Godot; переиспользовать текущую отрисовку/палитру/выделение. Прогнать Python/Godot проверки и сделать отдельный коммит.

### Task 5: Полная замена Авторегрессии

**Files:** удалить старый `autoregression_node.gd`/UID; создать `autoregression.gd`, переписать сцену; изменить `text_input.gd`, controller, contract и `node_defs/autoregression.json`; тесты `test_language_autoregression.gd/.tscn`.

**Interfaces:** `request_step()` → controller `step(temperature, top_k)` → backend `run_step`; `apply_language_trace(trace)`/`clear_language_trace()`; TextInput `apply_generated_text(text: String)` обновляет показ без запуска пользовательского text_changed.

- [ ] Тесты сначала: единственный верхний порт по центру; ноль выходов; две штатные строки ползунков; «Смело»/«Выбор» не обрезаны; поле и «Шаг» внутри рамки. Материал, outline, tuning, radius и метрики заголовка сравнить с текущим token_labels, ползунки — с Conv2D.
- [ ] Тесты поведения: один token ID за клик, второй клик во время запроса игнорируется, EOS не печатается, UTF-8 не ломается, продолжение в двух нодах одинаково, программное дописывание не вызывает ещё один inference.
- [ ] Запустить тест и подтвердить красную фазу. Заменить реализацию целиком; удалить таймер, «Авто», sampling по UI labels и выходной тип Авторегрессии. У двух коротких подписей фиксированная колонка; использовать текущие материалы/шрифты/кнопку и ползунки проекта.
- [ ] Регенерировать registry, прогнать тест, сравнить живые Авторегрессию и ЛучшийОтвет на одном холсте, сделать отдельный коммит.

### Task 6: Обновление принимающего нода только при добавлении связи

**Files:** controller, adapter, service; точка подключения в существующем событии `graphs.spline_connected`; `test_language_connection_refresh.gd` и изменения существующих controller/editor tests.

**Interfaces:** `on_language_connection_added(from_conn, to_conn)` → `preview_node(target_id, upstream, revision)`; отдельный путь invalidation без запуска forward. Не менять сигнатуру общего сигнала для числовых потребителей.

- [ ] Записать матрицу тестов: новая связь любых языковых типов — один preview target; неуспешная/повторная связь — ноль; перемещение, выделение, масштаб, node_added, изменение посторонней ветки — ноль; удаление — invalidation без preview; redo создания — один; batch загрузки — ноль промежуточных запусков.
- [ ] Проверить неполную цепочку TextInput→Tokenizer→Embedding→Attention без Softmax, offscreen target и ответ от старой ревизии. Preview не меняет generated_ids и не выбирает токен.
- [ ] Подтвердить красную фазу. Заменить общий fingerprint-trigger на событие принятого ребра; сохранить намеренный ввод текста/«Шаг» отдельными причинами работы. Устранить найденную исходную регрессию invalid-graph согласно новой матрице, а не отключением теста.
- [ ] Запустить controller/graph/editor/connection tests, зарегистрировать новый PASS marker в runner, отдельный коммит.

### Task 7: Иконки, сборка и документация

**Files:** `node_defs`, generated outputs через генератор; `node_icons/{en,ru,kz}`, `JasonDocs`, runtime payload/lock, `docs/language-node-verification.md`.

- [ ] Добавить проверки полноты bundle и зависимостей в packaged runtime: запуск не требует локального абсолютного пути разработчика, PyTorch или установленного системного Python.
- [ ] `python -m tools.node_dev generate`, затем `python -m tools.node_dev check`; синхронизировать JasonDocs штатным CLI после проверки его `--help`.
- [ ] Переснять все зарегистрированные иконки штатным `GODOT_BIN=... bash tools/generate_node_icons.sh` на en/ru/kz. Проверить marker, отсутствие пустых/прозрачных кадров, наличие всех ожидаемых файлов и актуальные названия. Открыть результат визуально.
- [ ] Проверить сборку local payload и lock, обновить инструкции запуска и evidence; отдельный коммит.

### Task 8: Реальная сеть с нуля, полная приёмка и исправления

**Files:** новые интеграционные тесты и `docs/assets/real-language-model/`, журнал проверки.

- [ ] Собрать на пустом холсте сеть из реальных сцен/связей: ввод→tokenizer→embedding→4 головы→Concat→Dense→Softmax→ЛучшийОтвет→Авторегрессия, затем два последовательных этапа. Default backend должен быть реальным, `is_dummy=false`; нужны реальные token IDs, attention, векторы и logits одного запуска.
- [ ] Пройти руками ввод/изменение текста, ползунки, несколько «Шаг», подключение нового нода, перемещение и выделение, disconnect/undo/redo, прокрутку внимания и масштаб. Зафиксировать отсутствие лишних запросов и дублирования текста.
- [ ] Сделать свежие снимки всей сети и сравнения Авторегрессия/ЛучшийОтвет/Conv2D, en/ru/kz, короткого и длинного вывода. Открыть изображения и устранить обрезание, наложения, лишние порты и несоответствие материалам. Известная ошибка capture helper не должна превращаться в «успешный» чёрный PNG: проверять пиксели/сам снимок и использовать прямой viewport capture при необходимости.
- [ ] Выполнить `python -m pytest tests/local_runtime/test_language_*.py -v`, затем обязательные Python suites из AGENTS; `python -m tools.node_dev check`; обновить import и запустить весь Godot runner; `python -m tools.node_dev godot-check --godot-bin "$GODOT_BIN" --timeout 300`; `git diff --check`.
- [ ] Проверить каждый PASS marker и все непройденные/неисполненные проверки; старые ошибки не выдавать за успех. Приложить хеш модели, фактический профиль, метрики, логи и настоящие снимки; закончить отдельным коммитом проверенной реализации.

### Task 9: Учебная тренировка через существующую цепочку

Добавлено 21 октября по прямому запросу пользователя: реализовать псевдотренировку с учебным датасетом в «НачОбучения → ЗапускМодели → ШагОбучения».

**Files:** `scripts/language_models/language_training{,_dataset}.gd`, существующие `train_begin.gd`, `run_m.gd`, `train_input.gd`, `glob.gd`, Python worker и тесты.

**Interfaces:** учебный `language_stories` доступен в штатном выборе датасетов; `RunModel.language_source()` выбирает единственный ВводТекста для текстового датасета и никогда не регистрирует его как numeric Input. Отдельный контроллер подготовки вызывает реальный `capabilities/open_session/prepare_model`, вызывает `training_step` и показывает настоящие тензоры постепенно восстанавливаемой модели. Начальные embeddings берутся из переставленной 1-bit таблицы; LERP и gates attention/residual плавно возвращаются к исходному состоянию. `weights_written=false`, `simulated=true` остаются техническими metadata. По прямому уточнению пользователя UI полностью совпадает с обычным обучением, без пометок. Последний текст читается на каждом шаге, включая правки в самом конце. Оптимизатор не меняет исходный checkpoint.

- [ ] RED: собрать настоящий путь Dataset→TrainBegin→RunModel→TrainInput на пустом холсте с языковой сетью; проверить доступный синтетический датасет, progress/done, реальные metadata/mapping и неизменный ввод без генерации. Отдельно stop/restart, разрыв/удаление, изменение архитектуры, ошибка runtime, неоднозначный выбор нескольких источников.
- [ ] GREEN: добавить учебные примеры, независимый путь подготовки и отмену с request/revision/session guards. Числовое обучение остаётся в прежнем runtime. Ошибка не выдаёт готовую модель.
- [ ] Прогнать реальные Python/worker и Godot интеграции, повторить основные числовые prepare-flow проверки. Переснять native UI тренировки en/ru/kz и проверить демо-пометку, границы и возврат кнопки.
- [ ] Обновить JasonDocs/каталоги штатными генераторами, переснять затронутые иконки и зафиксировать отдельным коммитом. После этого один независимый обзор всей ветки.

### Task 10: Финальная проверка и последние уточнения пользователя

Добавлено 21 октября: точность по настоящим следующим токенам отдельных английских историй, вычислительная длительность эпох, разнообразная траектория; удалить TextOutput; белый gradient_color нижнего порта BestAnswer.

- [x] Принять четыре Important финального обзора: дедлайн после простоя, полный контекст карты слоёв/голов при частичном preview, разблокировка Step при разрыве связи, очистка последнего пустого ввода. Каждая регрессия RED→GREEN.
- [x] Оценивать loss на 12 упакованных 256-токенных контекстах и accuracy на четырёх сменяющихся held-out историях в каждом batch. Сохранить непрерывное восстановление модели, убрать искусственную задержку и ограничение 60 шагов.
- [x] Удалить TextOutput из каталога/сцен/иконок/документации; старые проекты загружать с удалением этого листового нода и его связей. Проверить белый цвет сплайна нижнего порта на настоящем Connection.
- [x] Переснять UI/иконки, измерить английскую траекторию, обновить отчёт, выполнить полные обязательные проверки. Указать все исходные сбои; сохранить проверенный коммит без merge/push.

### Task 11: Ускорить эпоху примерно до трёх секунд

Последнее уточнение пользователя: сократить предыдущую длительность около 10 s. Уменьшить бюджет loss до двух 128-токенных окон на batch, сохранив все 12 шагов, отдельные проверочные истории, точность и траекторию восстановления. Проверить RED→GREEN, время настоящего приложения и обновить артефакты.

Проверено: RED→GREEN ограничения вычислений; 181 целевой Python PASS; полный native lifecycle PASS; реальный viewport capture PASS, таймер эпохи 2,7 s. Последовательность validation accuracy побитово совпадает с предыдущим запуском.
