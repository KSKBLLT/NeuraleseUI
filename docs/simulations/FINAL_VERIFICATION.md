# Neuralese Simulations: итоговая проверка

Дата проверки: 4 августа 2026 года.

## Что реализовано

- Визуальный редактор физического мира на нативной 2D-физике Godot.
- Три среды: машина сбоку, ровер сверху и летающий агент.
- Единый data-driven каталог объектов, сенсоров и актуаторов.
- Автоматическая и ручная привязка входов/выходов модели.
- Выделение, перемещение, вращение и изменение размера объектов с Undo/Redo.
- Генерация supervised dataset из последовательных физических эпизодов.
- Сохранение датасета через стандартный dataset engine Neuralese.
- Кнопка `Train`, использующая существующий training flow Neuralese.
- Строгий checkpoint contract: отсутствие checkpoint завершает обучение ошибкой.
- `Run` без demo controller: агент получает управление только от валидной обученной модели.
- Адаптивный интерфейс, Retina-масштабирование, macOS trackpad и Command shortcuts.

## Автоматические проверки

Godot:

```bash
GODOT_BIN="/path/to/Godot" bash tests/godot/run_all.sh
```

Результат: `41/41` тест прошёл. Набор включает редактор, три типа агентов,
сенсоры/актуаторы, runtime, генератор датасетов, training bridge, UI, Retina,
trackpad, Command/Ctrl и update flow.

Python/ONNX:

```bash
PYTHONPATH=local_runtime python -m unittest discover -s tests/local_runtime -v
```

Результат: `4/4` теста прошли. End-to-end тест выполняет настоящий цикл
`dataset -> training -> checkpoint -> inference`.

## Проверенная модель

Подготовленный пример находится в `examples/simulations/side_view_car`.

- Архитектура: `8 -> 32 -> 16 -> 2`.
- Epochs: `20`.
- Validation samples: `600`.
- Model MAE: `0.013971`.
- Constant baseline MAE: `0.199558`.
- Улучшение относительно baseline: `92.999%`.
- ONNX model и физический checkpoint сохранены и проверены.

## Ручной smoke-test

На macOS проверены:

- запуск настоящей сцены приложения;
- переключение всех трёх сред;
- открытие brain mapping;
- генерация и сохранение `20/20` samples;
- compact layout `576x360` и окно `1192x800`;
- отсутствие пересечений вкладок верхней панели при Retina scale `2x`.

Windows-логика покрыта автоматическими тестами одинаковых logical viewport,
Ctrl shortcuts и export preset. Нативный ручной smoke-test Windows нужно выполнить
на Windows-машине перед распространением пилотной сборки.

## Демонстрация

Итоговое видео: `artifacts/simulations-demo/neuralese-simulations-demo-final.mp4`.

Contact sheet для быстрой проверки сцен:
`artifacts/simulations-demo/demo-contact-sheet.png`.
