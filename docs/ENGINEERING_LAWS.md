# Инженерные законы и правила создания нод в Neuralese

> **Главный закон проекта:**  
> **«САМОЕ ЛУЧШЕЕ ПРАВИЛО В НЕЙРАЛИЗ — КОПИРОВАТЬ СУЩЕСТВУЮЩИЕ ЭЛЕМЕНТЫ»**  
> Никогда не создавайте сцены, компоненты и стили с чистого листа. Всегда находите эталонную ноду-донора (`softmax`, `conv2d`, `train_begin`, `layer_concat`) и копируйте проверенную структуру 1:1.

---

## 1. Анатомия ноды: Обязательное наследование `base_graph.tscn`

Все ноды на холсте обязаны быть производными от базовой сцены `res://scenes/base_graph.tscn`.

```ini
[gd_scene load_steps=... format=3]

[ext_resource type="PackedScene" uid="uid://dvy7srp0sk1qm" path="res://scenes/base_graph.tscn" id="1_base"]
[ext_resource type="Script" path="res://scripts/my_node.gd" id="2_script"]
...

[node name="Base" instance=ExtResource("1_base")]
script = ExtResource("2_script")
server_typename = &"MyNode"
```

### Инварианты корневого узла:
1. **Класс:** Скрипт ноды обязан наследовать `Graph` (`scripts/base_graph.gd`).
2. **Фильтр мыши:** `mouse_filter = Control.MOUSE_FILTER_IGNORE` (2). Корневой Control никогда не должен перехватывать события мыши, иначе клики не дойдут до холста и дочерних элементов.
3. **Корпус и шейдер `$ColorRect`:** Унаследован от `base_graph.tscn`. Использует `res://resources/graph.tres`.
   - Задает физические границы ноды для менеджера графов.
   - `instance_shader_parameters/outline_color`: цвет рамки.
   - `instance_shader_parameters/tuning`: цвет заливки.
4. **Заголовок `$ColorRect/root/Label`:** Тема `theme_base.tres`. Внутри обязан находиться дочерний узел `Loc` (`scripts/loc.gd`) со словарями для трех языков:
   ```gdscript
   localizations_ru = {"_": "МояНода"}
   localizations_kz = {"_": "МеніңНодам"}
   ```

---

## 2. Кнопки на ноде (`BaseBComponent.tscn`)

Кнопки внутри ноды — это инстансы `scenes/BaseBComponent.tscn` (`scripts/block_component.gd`).

### Критические настройки кнопок (нарушение ломает клики):
1. **`button_type = 1` (`ButtonType.BLOCK_BUTTON`)**:
   - **ОШИБКА:** По умолчанию в `BaseBComponent` стоит `0` (`CONTEXT_MENU`). В режиме `0` клик не генерирует событие, а пытается открыть контекстное меню.
   - **ПРАВИЛО:** Всегда явно выставлять `button_type = 1`.
2. **`mouse_filter = 1` (`MOUSE_FILTER_PASS`)**:
   - Кнопка должна пропускать события взаимодействия с графом.
3. **Ресурс `ButtonConfig` (`button_config.gd`)**:
   - Обязателен в поле `config`. Задает отклик при наведении, прижатие и цвет.
4. **Выравнивание текста:**
   - `alignment = Vector2(0.5, 0.5)` — центрирует текст внутри плашки.
5. **Вписывание текста и защита от переполнения:**
   - `resize_after = 4` (или длина короткого слова): при превышении этой длины `BlockComponent` автоматически сжимает шрифт, чтобы надпись не вываливалась из плашки.
   - `base_scale_x = 0.32` ... `0.4`: базовый масштаб шрифта.
   - `base_size = Vector2(width, height)`: обязано строго соответствовать `offset_right - offset_left` и `offset_bottom - offset_top`.
6. **Подключение сигналов:**
   - Сигнал `pressed` (или `released`) подключается к методу скрипта ноды:
     ```ini
     [connection signal="pressed" from="btn1" to="." method="_on_btn1_pressed"]
     ```

---

## 3. Слайдеры и параметры: Undo/Redo и контракт `_config_field`

Параметры ноды не хранятся в случайных переменных. Они синхронизируются с ядром `Graph`.

### Изменение значения (ввод пользователем):
```gdscript
func _on_slider_value_changed(value: float) -> void:
    open_undo_redo()
    update_config({"my_param": int(value)})
    close_undo_redo()
```

### Реакция на изменение (Undo, Redo, десериализация):
`Graph` автоматически вызывает виртуальный метод `_config_field`:
```gdscript
func _config_field(field: StringName, val: Variant) -> void:
    match field:
        "my_param":
            $Label/n.text = str(val)
            $Label/HSlider.value = float(val)
```

---

## 4. Порты ввода/вывода (`scenes/Connection.tscn`)

Порты ноды создаются инстанцированием `scenes/Connection.tscn`:
* **Входной порт:** `connection_type = 0`, `dir_vector = Vector2(-1, 0)` (или `(0, -1)`).
* **Выходной порт:** `connection_type = 1`, `dir_vector = Vector2(1, 0)` (или `(0, 1)`).
* **Свойства:**
  - `parent_graph = NodePath("..")`
  - `_accepted_datatypes = "layer1d"` (или `activation`, `scores`, `autoregression`)
  - `server_name = &"unique_port_name"`

---

## 5. Жизненный цикл `GraphManager`: Оптимизация и обработка мыши

1. **`GraphManager.process_mode`**:
   - `GraphManager` постоянно проверяет ноды на холсте (`scripts/graph_manager.gd:1403-1450`).
   - Если курсор мыши не находится над границами `node.rect` и у ноды нет активных связей, менеджер **принудительно выставляет `process_mode = PROCESS_MODE_DISABLED`**.
   - Нода в `DISABLED` не крутит `_process` и полностью игнорирует события Godot.
2. **`is_mouse_inside()` и `top_graph_at_mouse`**:
   - Нода получает право реагировать на мышь **только тогда**, когда `graphs.top_graph_at_mouse == self`.
   - Захват определяется строго по `node.rect: ColorRect`. Если `ColorRect` настроен неверно, нода никогда не получит фокус мыши.

---

## 6. Регистрация источника правды (`node_defs/*.json`)

> **Запрет:** Никогда не редактируйте вручную файлы в `scripts/generated/` и `node_defs/generated/`. Они полностью перезаписываются генератором.

### Создание манифеста `node_defs/<node_id>.json`:
```json
{
  "schema_version": 1,
  "id": "my_node",
  "source": {
    "kind": "scene",
    "path": "res://scenes/my_node.tscn"
  },
  "load_order": 220,
  "menu": {
    "visible": true,
    "section": "language",
    "order": 90
  },
  "roles": [],
  "llm": {
    "type": "my_node"
  },
  "runtime": {},
  "display": {
    "title": {
      "en": "MyNode",
      "ru": "МояНода",
      "kz": "МеніңНодам"
    },
    "outline_color": "#66b2ffff"
  }
}
```

### Правила полей:
* `load_order`: **Уникальное число**. Коллизия с существующим `load_order` вызовет ошибку генератора.
* `runtime`: если у ноды нет Python ONNX-обработчика (например, интерфейсная нода или языковая нода), указывать пустой словарь `{}`. Если обработчик есть — он обязан быть зарегистрирован декоратором `@handles` в Python-рантайме.

### Команды валидации и генерации:
```bash
python -m tools.node_dev generate   # Пересобрать каталоги
python -m tools.node_dev check      # Проверить целостность реестра (29 нод)
```

---

## 7. Каноничный генератор превью и иконок (`node_icons`)

Иконки нод палитры генерируются **только через официальный CLI-скрипт**. Никаких правок в `node_palette_item.gd` или ручных скриншотов!

### Команда генерации:
```bash
# Генерация для конкретной ноды
GODOT_BIN=/path/to/godot bash tools/generate_node_icons.sh --node-icon-types=my_node

# Или напрямую через Godot CLI (Windows PowerShell):
& $GODOT_BIN --path . -- --generate-node-icons --node-icon-types=my_node
```

### Как это устроено под капотом:
1. Аргумент `--generate-node-icons` перехватывается в `scripts/glob.gd:3440` **до старта интерактивного UI**. Модальные окна онбординга и сплэши не открываются.
2. `scripts/project.gd` вызывает `graphs.generate_previews()`.
3. Для каждого языка (`en`, `ru`, `kz`) движок центрирует камеру в `(0, 0)`, спавнит ноду на чистом фоне, делает точный снимок `node.rect` и сохраняет:
   - `res://node_icons/en/IconMyNode.png`
   - `res://node_icons/ru/IconMyNode.png`
   - `res://node_icons/kz/IconMyNode.png`
4. При следующем запуске Godot (или `godot --headless --import`) движок компилирует `.ctex` и создаёт файлы `.png.import`.
5. Палитра находит иконку штатным методом `ResourceLoader.exists("res://node_icons/<lang>/IconMyNode.png")`.

---

## 8. Архитектура языковых моделей (`language_models`)

Языковые ноды подчиняются строгому контракту:
1. **DAG-инвариант:** На холсте граф всегда направленный и ацикличный (никаких обратных проводов).
2. **Контракт типов:** Все типы данных портов объявляются в `scripts/language_models/language_contract.gd` (`OPS`, `INPUT_TYPES`, `OUTPUT_TYPES`).
3. **Оркестрация:** Управление шагами генерации (`step()`, `continue_generation()`) осуществляет `LanguageGraphController`. Ноды не ищут `text_input` по дереву сцен вручную — обратная связь и передача токенов реализуются через контроллер и подписку на состояние.
