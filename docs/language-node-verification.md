# Реальная языковая модель — 21 октября 2026

База: `origin/robot-integration`, коммит `4f590d8a9d2547e49f05844177d22a36d803578e`. Изменения выполняются в отдельной ветке `codex/real-language-model`.

## Модель и данные

Production backend — `onnx-clean1000`, `is_dummy=false`. Резидентный Python worker использует CPU ONNX Runtime, настоящий tokenizer checkpoint и ChatML-шаблон. Ошибка отсутствующего комплекта показывается явно; автоматической подмены на dummy нет. Dummy/VocabBackend инжектируются только в отдельные unit-фикстуры.

Checkpoint clean1000: 10 блоков, hidden 256, 4 query heads / 2 KV heads, head_dim 64, словарь 20 002. Контекст ограничен 512 токенами вместе со скрытым шаблоном чата, продолжение — 32 новыми токенами. ONNX-копия открывает существующие промежуточные тензоры, сохраняя веса и исходные logits. Тесты сравнивают logits с оригиналом (`rtol=atol=4e-4`), полный forward и cached decode, causal mask, реальные embeddings и EOS.

Ввод текста обновляет визуализации после паузы 300 мс, не выбирая следующий токен. «Шаг» выполняет один числовой sampling в runtime и дописывает декодированное продолжение во ВводТекста и Авторегрессию. Программное дописывание не запускает новый запрос. Быстрый повторный клик во время запроса игнорируется.

## Приблизительная адаптация

Последовательные AttentionHead задают визуальные этапы; параллельные выбирают разные реальные головы одного этапа. Dense/Concat/Softmax сохраняют штатный UI. Фактические размеры тензоров берутся из checkpoint, поэтому пользовательская ширина Dense не обязана совпадать с hidden/vocab. Карта содержит requested_depth, effective_depth, profile_id и физические слои каждого этапа.

Сравнены BI-pruning и соседние LERP/SLERP для глубин 2/4/6, с отдельными calibration/held-out примерами. Ни один агрессивный профиль не прошёл заданные пороги качества. Поэтому runtime сохраняет все 10 физических блоков и группирует их в визуальные этапы; конфигурации 8–12 также сохраняют оригинальные веса. Это не ускорение до двух физических слоёв. Полный отчёт: [compression-research.json](assets/real-language-model/compression-research.json).

Источники исследования: [ShortGPT](https://aclanthology.org/2025.findings-acl.1035/), [LaCo](https://aclanthology.org/2024.findings-emnlp.372/), [SliceGPT](https://arxiv.org/abs/2401.15024).

## Эмбеддинги слов

Отображаются целые слова, не отдельные byte-токены. Сначала embeddings объединяются по исходным Unicode-символам; перекрывающие байтовые токены делят вес символа. Для устойчивого положения одного слова используются канонические casefold embeddings того же настоящего словаря. Все исходные ID и позиции остаются доступны для выделения.

Фиксированная линейная relation-constrained PCA согласует направления мама→папа и королева→король. Координаты не подставляются по названиям слов и не пересчитываются при добавлении соседних слов. Камера графика центрирует видимые слова и применяет один общий масштаб: точки занимают доступную площадь без искажения углов и соотношений расстояний. Отдельные точки не раздвигаются искусственно. Это учебная проекция: anchor-пары имеют cosine 1 и одинаковую длину, но held-out отношения заметно хуже, recall ближайших соседей@10 — 0,16. Матрица и метрики: [word-projection.json](assets/real-language-model/word-projection.json). Исходные 256-мерные векторы не меняются. Цвет YlGn показывает третью ось проекции; атрибуция — [ColorBrewer](licenses/ColorBrewer.txt). По уточнению пользователя зелёные соединительные линии и полоса цветовой шкалы убраны.

Обоснование ограничений линейных аналогий: [Analogies Explained](https://proceedings.mlr.press/v97/allen19a.html).

## Соединения и UI

Только принятое добавление связи между языковыми/sequence-capable нодами запрашивает `preview_node` принимающей ноды. Частичная цепочка без Softmax поддерживается. Запросы соединений ставятся в очередь, контроллер работает и вне экрана. Перемещение, выделение, масштаб, новая несвязанная нода и изменение параметров не запускают forward. Частичный preview использует карту полного компонента, поэтому параллельные головы и физические слои не пересчитываются по одной ветке. Порядок голов сохраняется в конфигурации, включая загрузку и undo. Удаление связи отменяет устаревшую работу, освобождает кнопку «Шаг» и очищает downstream; batch загрузки не запускает промежуточные preview. Request ID, session ID и graph revision проверяются до применения ответа.

Авторегрессия написана заново. Старая реализация с Auto/таймером/выбором по подписям удалена. Рамка, радиус, цвета и заголовок скопированы с актуального BestAnswer; длина ползунков и положение значений — с Conv2D; кнопка «Шаг» копирует компактную «Доб» из ВыводОтвет (88×42 до штатного масштабирования). Единственный порт находится сверху по центру, выходов нет. Оба порта генерации рисуются под телом нод и имеют тот же зелёный цвет, что вход BestAnswer. Выступ каждого порта равен 8 px, как у левого входа; у нижнего BestAnswer gradient_color белый и передаётся сплайну. Подписи — «Смело» / «Выбор», далее поле и «Шаг». Неиспользуемая дублирующая сцена `top_output_graph.tscn` удалена; в каталоге остаётся один BestAnswer, отдельного NextToken нет. TextOutput удалён из сцен, каталога, иконок и обработчиков. При загрузке старого проекта этот листовой нод и его связи удаляются, остальные ноды сохраняются.

«Датасет → НачОбучения → ЗапускМодели → ШагОбучения» поддерживает `language_stories`: 12 синтетических английских историй и 12 отдельных проверочных историй в штатном выборе датасетов. Отдельный контроллер подготовки загружает настоящий worker и восстанавливает модель по 12 batch на каждую заданную эпоху; скрытого ограничения 60 шагов больше нет. У embeddings используется LERP от переставленной однобитной таблицы к оригинальной. Валидные attention scores до causal mask и вклад attention/MLP управляются непрерывными gates. Поэтому начало имеет равномерный causal attention и повреждённые embeddings; при прогрессе 1 используется исходная ONNX-сессия, с точным совпадением logits/attention. Исходный checkpoint не перезаписывается, backprop не выполняется.

По прямому запросу пользователя визуальное оформление полностью совпадает с обычной тренировкой, без дополнительных пометок. График вычисляет top-1 next-token accuracy по правильным продолжениям четырёх сменяющихся проверочных историй. Это отдельные примеры, а не совпадение с исходной моделью: восстановление не заставляет точность достигать 100%. В каждом batch дополнительно вычисляется cross-entropy на 2 упакованных контекстах по 128 токенов: 254 учебные цели плюс проверочные цели. Время эпохи определяется настоящими ONNX-прогонами и расчётом loss; искусственная задержка удалена. Смена проверочных batch сохраняет неровную траекторию. Метрики и время конкретного английского запуска — [learning-restoration.json](assets/real-language-model/learning-restoration.json). На Apple M5 проверенная эпоха заняла около 3 s; точность прошла 0 → 6,5 → 5,0 → 10,7 → 18,8 → 16,9%. Это измеренный результат выбранных историй, без фиксированного конечного процента. Слова, внимание и лучший ответ поступают из одного реального forward восстанавливаемой модели для текущего ВводТекста. Правки текста, включая последний кадр обучения, подхватываются без перезапуска. Текущие предсказания видны в BestAnswer, без дописывания символов в источник; sampling во время обучения заблокирован. Stop/restart, удаление/разрыв цепочки и ошибки checkpoint не оставляют управление заблокированным. Несколько ВводТекста требуют устранить неоднозначность; числовая регистрация моделей не изменялась.

С 21 октября по запросу пользователя график и процент accuracy **только языкового обучения** показывают `clamp(raw_accuracy × 4, 0, 1)`. Исходные `validation_accuracy`, loss и сохранённые runtime-метрики остаются измеренными значениями; числовое обучение не масштабируется. Приведённые выше исторические замеры 0 → 16,9% относятся к исходной метрике до display-множителя.

[Начальное состояние](assets/real-language-model/learning-initial.png), [середина](assets/real-language-model/learning-middle.png), [восстановленная модель](assets/real-language-model/learning-restored.png), [цепочка RU](assets/real-language-model/ru-language-training.png), [готовый проект с обучением](assets/real-language-model/clean1000-training-network.nls).

[Сравнение на одном холсте](assets/real-language-model/autoregression-best-answer.png). Ранее снятые исходные состояния: [BestAnswer](assets/real-language-model/baseline-best-answer.png), [сеть](assets/real-language-model/baseline-network.png).

Пересняты все 28 зарегистрированных нод на en/ru/kz: 84 изображения, плюс английские aliases для старых путей. Исправлен захват: toolbar больше не перекрывает высокий BestAnswer. Проверены непустые кадры и визуально открыты BestAnswer, Авторегрессия, InputRGB и локализованный Токенизатор. [Отчёт генерации](assets/real-language-model/icon-generation.json). JasonDocs и runtime catalog пересобраны из исходных деклараций.

## Подготовка и запуск

```sh
export PYTHONPATH=local_runtime:.
# Python 3.11 с зависимостями local_runtime/requirements.txt.
python -m tools.language_models.prepare_bundle --source /path/to/Neuralese-Model-Kit
python -m tools.language_models.prepare_bundle --verify
```

Минимальный inference-комплект `local_runtime/models/clean1000` включён в Git: decoder, tokenizer, config, шаблон и manifest с проверкой хеша/размера каждого файла. Поэтому обычный pull доставляет веса на другой компьютер; исходный большой kit, safetensors/PyTorch и производные модели не версионируются. Исходный комплект не изменяется.

Экспорт полностью автономен: встроенный Python/ONNX, модель и небольшие offline-библиотеки находятся внутри `local_runtime`. Tokenizers 0.22.2, Jinja2 3.1.6 и MarkupSafe 3.0.3 включены в `language_vendor` вместе с лицензиями и хешами. Hub, Torch и Transformers не требуются. Пользователь не устанавливает Python/pip или зависимости; внешняя папка модели и окружение в домашнем кэше не используются. Переменная `NEURALESE_LANGUAGE_PYTHON` разрешена только для явных editor/test-запусков.

Каждый Windows builder и сборщик установщика накладывает актуальные веса/библиотеки из checkout на базовый runtime и запускает `check_language_runtime.py` его собственным Python с `-I`. Проверка отклоняет импорты извне local_runtime, запрещает сетевые соединения, проверяет английскую генерацию `red cup` и реальные карты внимания с пустым производным кэшем. Отсутствующие файлы/библиотеки останавливают сборку. Ошибка импорта также возвращается через протокол; traceback сохраняется в `user://language-runtime/workers/<id>/worker.log`.

Второй ORT не устанавливается; используется прежний training-cpu 1.19.2. Lock основных библиотек соответствует requirements; версии дополнительных offline-библиотек зафиксированы отдельным vendor manifest. [Источники исходного lock](assets/real-language-model/runtime-metadata-sources.json). Тест компилирует пакет в sourceless `.pyc`, переносит bundle и запускает реальный LanguageEngine без импорта Torch/Transformers. Windows `.exe` нельзя проверить исполнением на macOS; для проверки Windows используется отдельный нативный CI smoke.

## Изолированный Windows-экспорт — 21 октября 2026

[Нативная проверка Windows](https://github.com/Neuralese-LLP/neuralese-builder/actions/runs/39575945035)
прошла на `82441ac`. Release EXE собран прежним `export_windows_with_runtime.ps1`.
Папка приложения перенесена; исходный `local_runtime` убран. Профиль,
AppData и LocalAppData пустые; PATH содержит только Windows, внешние Python/model
переменные удалены. Windows Firewall запрещает исходящие подключения EXE и
встроенному Python. Контрольное соединение тем же Python успешно до запрета и
возвращает 10013 после него. Все проверенные Python-библиотеки находятся внутри
экспортированного `local_runtime`.

Внутри самого EXE прошли токенизация, настоящие attention/word embeddings,
greedy-ответ `red cup`, prepare_model и training_step при progress 0/1 с новым
английским вводом. Для запуска используется тестовая сцена, выбранная только в
CI checkout: официальный release-шаблон Godot 4.7 отключает CLI `--script`.
Обычная конфигурация приложения и экспортёр не меняются. Регрессия Windows
кодировки кэша проекции исправлена явным UTF-8 при чтении и записи.

Это headless-приёмка языкового backend в EXE. Весь установщик и обычный UI этим
прогоном не проверяются; предыдущую попытку полной сборки остановило скачивание
CIFAR-10. В журнале остаются сообщения autoload про Windows system directory,
невалидные сохранённые Variant и ресурсы при завершении; отсутствие ошибок всего
приложения не заявляется. [Условия, результаты и вывод](assets/real-language-model/windows-offline-runtime.json).
Свежий целевой pytest-набор: 195 PASS, включая два исследовательских теста.

## Повторить проверки

```sh
PYTHONPATH=local_runtime:. python -m pytest tests/local_runtime/test_language_*.py -v
python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration -v
python -m tools.node_dev check
python -m tools.jasondocs validate
NEURALESE_RUN_REAL_LANGUAGE_TESTS=1 GODOT_BIN=/path/to/Godot bash tests/godot/run_all.sh
python -m tools.node_dev godot-check --godot-bin /path/to/Godot --timeout 300
```

Для реальной приёмки требуется установленный checkpoint; отсутствующие файлы считаются ошибкой. Обычный unit/CI runner явно сообщает, что реальная приёмка включается `NEURALESE_RUN_REAL_LANGUAGE_TESTS=1`, и не скачивает веса.

Текущие подтверждённые проверки: обязательные Python node_dev/JasonDocs/release/integration — 125 PASS; языковой runtime — 56 PASS, вместе 181 PASS. Node developer check и Godot scene source check — 28 нод PASS; JasonDocs validation — PASS (пять сохранённых предупреждений о прежних скрытых папках).

Полный Godot runner с настоящей моделью: 97 PASS / 7 FAIL. Все семь сбоев воспроизведены на чистом `4f590d8`: remote_transport_guards, remote_action_behavior, local_training_worker, project_gallery, builtin_projects_blur_release, settings_quality_carousel, simulation_tab. [Результаты чистой базы](assets/real-language-model/baseline-test-results.json). Проверки настоящей сети, обучения, отмены, последнего пустого ввода, UI, соединений, редактора и undo/load проходят. Тесты реальных сцен используют штатный `--perfbench`, чтобы стартовая заставка приложения не отключала обработку кнопок графа.

Дополнительно выполнен полный `python -m pytest -q`: **719 PASS, 12 SKIP, 51 FAIL, 2 ERROR**. Все 53 непройденные проверки присутствуют в таком же прогоне чистой базы: там **662 PASS, 12 SKIP, 52 FAIL, 2 ERROR**. Новых Python-сбоев нет; ещё один прежний release-тест исправлен обновлением runtime lock. Основная причина — недоступный `onnxruntime.training.api` числового runtime на macOS; отдельно воспроизводится старый race состояния dummy robot (`idle`/`driving`). Полные имена каждого сбоя и сравнение: [python-suite-results.json](assets/real-language-model/python-suite-results.json).

Финальный свежий обзор обнаружил четыре Important; все исправлены с RED→GREEN регрессиями. [Находки и решения](assets/real-language-model/final-review.json). У целевого набора нет новых сбоев; общие исходные сбои не объявляются успехом. Изменения находятся в ветке `codex/real-language-model`; слияние в целевую ветку не выполнялось.

## Сеть и свежие снимки

[Импортируемый проект Neuralese](assets/real-language-model/clean1000-network.nls), [вся сеть](assets/real-language-model/real-network.png), [английские слова и внимание](assets/real-language-model/real-english-embedding-attention.png), [сравнение RU](assets/real-language-model/ru-autoregression-best-answer-conv2d.png), [длинный вывод KZ](assets/real-language-model/kz-long-output.png), [машиночитаемая приёмка](assets/real-language-model/real-network-acceptance.json). Все кадры получены прямым viewport capture и открыты для визуальной проверки. Короткий greedy-ответ: IDs `[768, 7700]`, текст `red cup`; длинный ответ — 21 настоящий токен.

Дополнительные регрессии, найденные при приёмке: полная attention-матрица вместо обрезания восьми BPE-токенов, точная проверка кеша матрицы, сортировка малых вероятностей без approximate ties, стабильный порядок подписей равных вероятностей, исключение кнопки/ползунков из перетаскивания ноды, читаемые ByteLevel-пиллы по исходным Unicode spans и разведение подписей близких слов без перемещения точек.
