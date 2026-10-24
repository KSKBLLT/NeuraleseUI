# Neuralese Node Developer Tool

Это инструмент этапа разработки. Он собирает регистрацию нод из `node_defs/*.json` в статические каталоги Godot, local runtime и JasonDocs. В готовом приложении нет обхода папок, чтения JSON, динамической регистрации или ручного прогрева. Все источники записаны как Godot `preload(...)`; создание ноды только берёт готовый `PackedScene` и вызывает `.instantiate()`.

## Что остаётся прежним

Сцена ноды по-прежнему наследует `Graph`/`BaseGraph` и может использовать любые существующие механизмы проекта:

- `Connection.tscn` и обычные/динамические порты;
- шаблон `unit` и `_get_unit()` для повторяемых строк;
- `_config_field()`, `_useful_properties()`, `_map_properties()` и другие override-хуки;
- существующие кнопки, поля, слайдеры, сетки и визуализации Conv2D/MaxPool/Dense;
- дочерние `Loc` для названий и свойств.

Инструмент не создаёт второй UI-фреймворк. Команда `inspect` извлекает из сцены порты, настройки, используемые PackedScene-компоненты, дерево контролов и override-хуки, чтобы разработчик или LLM сначала переиспользовал уже существующие паттерны.

## Обычный путь: существующая сцена

1. Создать и проверить `.tscn`, наследующий `BaseGraph`, обычным способом.
2. Зарегистрировать сцену одной командой:

```powershell
python -m tools.node_dev new attention `
  --scene res://scenes/attention.tscn `
  --visible --section layers `
  --llm-type attention `
  --runtime-handler neuron_layer `
  --default-input-port layer_in `
  --default-output-port layer_out
```

Названия `en`, `ru`, `kz`, цвета, порты и архитектурные паттерны будут извлечены из сцены. `--title-*` и `--*-color` нужны только для намеренного переопределения.

Команда сразу создаёт декларацию, проверяет сцену и обновляет каталоги. Если сцена не наследует `BaseGraph`, в ней нет обязательной локализации или конфликтуют алиасы, регистрация завершается ошибкой.

## Local runtime

Поле `runtime.handler` указывает не на тип ноды, а на реализацию поведения. Несколько визуально разных нод могут безопасно использовать один обработчик, например `neuron_layer`.

Для нового поведения нужно написать сам обработчик в `local_runtime/neuralese_local/onnx_node_handlers.py`:

```python
@handles("attention")
def compile_attention(ctx, nid, ntype, props, config, emit):
    ...
```

Алиасы Godot/server-типа перечисляются только в декларации ноды. Их больше не нужно копировать в декоратор. Генератор проверяет, что указанный обработчик существует, и записывает готовую таблицу типов для Python runtime.

## Программный провайдер — задел для будущих сцен

Для ноды, которую требуется собрать кодом, доступен статически подключаемый провайдер:

```powershell
python -m tools.node_dev new procedural_demo `
  --provider res://scripts/node_providers/procedural_demo.gd `
  --title-en "Procedural Demo" `
  --title-ru "Программная нода" `
  --title-kz "Бағдарламалық нод"
```

CLI создаст заготовку с контрактом:

```gdscript
func instantiate_node(definition: Dictionary) -> Graph:
    # Собрать Graph из уже существующих сцен и компонентов.
```

Провайдер, как и сцены, записывается dev-инструментом в отдельный Godot-каталог с `preload(...)`. Никакого поиска классов, `load()` или прогрева при создании ноды нет. Это намеренно небольшой задел: текущие `.tscn` не мигрируются и программная система визуальных компонентов пока не навязывается.

## Команды

```powershell
python -m tools.node_dev list
python -m tools.node_dev inspect conv2d
python -m tools.node_dev discover
python -m tools.node_dev validate
python -m tools.node_dev generate
python -m tools.node_dev check
python -m tools.node_dev godot-check --godot-bin C:\path\to\godot.exe
```

- `list` показывает единственный реестр нод и их runtime-обработчики.
- `inspect` выдаёт машинно-читаемый контракт сцены для разработчика/LLM.
- `discover` находит незарегистрированные `BaseGraph`-сцены, но ничего не добавляет автоматически. Поэтому мусорные и экспериментальные сцены не становятся доступными пользователю.
- `validate` проверяет строгую схему, источники, локализации, порядок, алиасы и runtime-обработчики.
- `generate` обновляет файлы только при изменении содержимого.
- `check` используется в CI и падает, если декларации и каталоги разошлись.
- `godot-check` — явная проверка этапа разработки. Она запускает редакторскую сборку Godot с флагом `--node-dev-validate` и проверяет, что все заранее сгенерированные `PackedScene` можно создать. Флаг заблокирован проверкой `OS.has_feature("editor")`, поэтому экспортированное приложение его не выполняет. При обычном запуске приложения эта ветка тоже не запускается.

## Единственный источник правды

Редактируется только `node_defs/<node_id>.json`. Схема находится в `tools/node_dev/node_definition.schema.json`.

Генерируемые файлы нельзя править вручную:

- `scripts/generated/node_catalog.gd` — меню, порядок загрузки, названия, цвета и LLM-алиасы Godot;
- `scripts/generated/node_sources.gd` — готовые `preload` сцен/провайдеров и их создание;
- `local_runtime/neuralese_local/generated_node_catalog.py` — server-типы, обработчики, роли и порты local runtime;
- `node_defs/generated/catalog.json` — полный dev/LLM-инвентарь сцен, портов, настроек, компонентов и override-хуков.

JasonDocs берёт список доступных нод из тех же деклараций. `menu.visible: false` исключает dev-ноду из меню и документации, но оставляет возможность загрузить старый граф с этим типом, если сама нода зарегистрирована.

Перед коммитом достаточно выполнить:

```powershell
python -m tools.node_dev generate
python -m tools.node_dev check
python -m pytest tests/node_dev tests/jasondocs
```
