# Prepared local training runtime

## Цель и fast path

FullyLocal-обучение использует резидентный Python worker и заранее подготовленную
ORT Training session. В подготовленном состоянии нажатие кнопки не импортирует
Python-модули, не перечитывает датасет и не генерирует training artifacts:

```text
COLD
  -> RUNTIME_READY      Python, NumPy, ONNX и ORT импортированы
  -> DATASET_READY      built-in датасеты находятся в RAM
  -> ARTIFACTS_READY    training/eval/optimizer graphs находятся в cache
  -> SESSION_READY      Module, Optimizer и fresh checkpoint загружены
  -> TRAINING           START начинает первый настоящий batch
```

Worker запускается из `RunManager._ready()` отложенно, после первого кадра. Ни
startup UI, ни onboarding не ожидают его готовности. После стабилизации графа в
течение 400 мс `RunManager` отправляет `PREPARE`; нажатие «Обучить» отправляет
короткую команду `START` с идентификатором подготовленной session.

Обычный старт всегда восстанавливает fresh checkpoint. Продолжение обучения
возможно только через явно переданный resume checkpoint: обученные веса и
optimizer state никогда не переиспользуются молча.

## Границы и fallback

- Worker принимает authenticated length-prefixed JSON только через loopback TCP.
- Одновременно существуют одна prepared session и не более одного active job.
- `graph_generation`, fingerprint, dataset revision и `prepared_id` защищают от
  применения устаревшего результата подготовки.
- Progress ограничен 10 событиями в секунду; lifecycle/epoch/error проходят без
  задержки. STOP хранится в памяти и проверяется между batch.
- Старый one-shot путь через `train_entry.py` и job directory сохранён. Если
  worker не запустился, PREPARE отклонён или session устарела до START, Godot
  выполняет fallback ровно один раз.
- Уже начавшееся обучение не переигрывается автоматически на другом backend.

## Датасеты и память

Все успешно загруженные built-in датасеты удерживаются worker-ом в памяти.
Пользовательский `dataset.json` не менялся: распарсенные массивы кэшируются по
canonical path, revision, size и `mtime_ns`. Только пользовательская часть cache
ограничена LRU-бюджетом 512 MiB.

`ArrayDataset.batch_indices()` переиспользует shuffle index и batch buffers.
Изображения могут оставаться `uint8`/mmap и преобразуются в `float32` только для
текущего batch; маленькие таблицы материализуются целиком.

На измеренной машине резидентный процесс занимал около 285 MiB для табличных
задач и около 500 MiB после загрузки MNIST. Это осознанный обмен памяти на
мгновенный fast path.

## Cache и диагностика

Godot хранит состояние worker в:

```text
user://fullylocal/training_worker/
  bootstrap.json
  artifacts/
  datasets/
  prepared/
  profile_calibration.json
  training_capabilities.json
```

Checkpoints проектов остаются в `user://fullylocal/checkpoints/<project_id>`.
One-shot jobs и exports остаются соответственно в `user://fullylocal/jobs` и
`user://fullylocal/exports`.

Artifact key включает канонический граф, формы и dtype, trainable parameters,
loss, optimizer, ORT version/ABI, платформу, CPU capability, выбранный формат и
schema version. Запись cache строится под lock во временной директории,
проверяется по SHA-256 и публикуется атомарным rename.

Capability probe создаёт и реально загружает минимальный training graph. На
bundled ORT 1.19.2 выбран ORT-format, потому что он загружается быстрее ONNX.
Nominal checkpoint не прошёл настоящий `TrainStep`, поэтому runtime безопасно
использует complete checkpoint. Выбор сделан измерением, а не проверкой номера
версии.

Stage timings (`dataset`, `model`, `artifacts`, `checkpoint`, `module`,
`optimizer`, `first_step`, `eval`, `export`, `save`) входят в lifecycle packets
и итоговый manifest.

## Профили CPU

Профиль не зависит от названия датасета. Он вычисляется по числу примеров,
размеру примера, числу параметров и оценке MAC для Conv/MatMul/Gemm:

| Профиль | ORT execution | intra-op | inter-op | spinning |
|---|---|---:|---:|---|
| Tiny | sequential | 1 | 1 | off |
| Small | sequential | 1-2 | 1 | off |
| Heavy | sequential | 1/2/4 по calibration | 1 | off |

Heavy calibration ограничен 750 мс, выполняется во время фонового warm-up и
кэшируется по CPU и ORT version.

## Benchmark 2026-09-17

Машина: Intel Core i7-11370H, 8 logical CPU, Windows 10 build 26200. Она быстрее
целевого четырёхпоточного i5, поэтому абсолютные значения нужно перепроверить на
целевом ноутбуке. Hot и warm измерены по 20 раз без удаления выбросов; настоящий
cold process — по 3 раза. `click -> first` включает fresh-state reset и первый
реальный `TrainStep`.

### Hot: worker, dataset, artifacts и session уже готовы

| Сценарий | click -> first p50 / p95, мс | epoch p50 / p95, мс | eval p50 / p95, мс | export p50 / p95, мс | total p50 / p95, мс | peak RSS, MiB |
|---|---:|---:|---:|---:|---:|---:|
| Iris Dense | 6.51 / 14.79 | 0.80 / 2.21 | 0.36 / 1.62 | 9.00 / 20.19 | 18.44 / 37.08 | 284.4 |
| Titanic Dense | 4.71 / 6.45 | 1.56 / 2.24 | 0.39 / 0.58 | 6.46 / 7.79 | 14.66 / 16.67 | 284.6 |
| MNIST MLP | 8.30 / 11.62 | 196.84 / 268.24 | 13.88 / 20.21 | 30.21 / 107.58 | 239.37 / 360.75 | 497.9 |
| MNIST Conv | 10.16 / 18.75 | 501.37 / 618.10 | 33.00 / 41.95 | 30.81 / 51.17 | 548.21 / 664.90 | 502.1 |

Hot p95 меньше 50 мс во всех четырёх сценариях. Export не находится на пути до
первого шага и выполняется один раз в конце.

### Warm: runtime и cache готовы, session создаётся заново

| Сценарий | prepare p50 / p95, мс | click -> first p50 / p95, мс | total p50 / p95, мс |
|---|---:|---:|---:|
| Iris Dense | 7.36 / 11.70 | 2.16 / 3.32 | 12.24 / 15.46 |
| Titanic Dense | 6.82 / 13.98 | 2.01 / 2.78 | 11.53 / 16.83 |
| MNIST MLP | 9.69 / 33.98 | 3.67 / 6.92 | 244.66 / 306.96 |
| MNIST Conv | 12.24 / 18.06 | 4.42 / 6.42 | 557.08 / 651.68 |

### Cold: новый Python process на каждый запуск

| Сценарий | process total p50 / p95, мс | training task p50 / p95, мс |
|---|---:|---:|
| Iris Dense | 694.58 / 731.03 | 225.90 / 261.18 |
| Titanic Dense | 668.26 / 725.95 | 228.94 / 243.78 |
| MNIST MLP | 2006.83 / 2164.58 | 997.23 / 1198.04 |
| MNIST Conv | 2250.72 / 2373.88 | 1335.59 / 1339.28 |

Cold process показывает внешний предел загрузки Python/DLL/ORT. Он устранён из
пользовательского клика warm-up-ом, но физически не может быть нулевым при первом
запуске процесса.

## Алгоритмическое ускорение эпох 2026-09-18

После устранения runtime overhead добавлены две аппроксимации steady-state
обучения: selective block execution с 80% покрытием стабильных batch и
progressive suffix freezing с переносом полного parameter buffer между ORT
session. Последняя эпоха и каждая пятая refresh-эпоха остаются полными.

Политика не смотрит на имя датасета. Если при выбранном batch получается меньше
8 batch на эпоху, приблизительный режим не включается: на таких задачах он не
окупает переключение session и может зря ухудшить качество. Поэтому Iris и
Titanic ниже проходят тем же exact path в обеих когортах.

Измерение выполнено на той же машине с Intel Core i7-11370H. Для каждой
архитектуры использован ABBA-порядок, две пары одинаковых initialization seed,
одна отдельная warm-up эпоха и 6 измеряемых эпох на запуск. Batch size — 128.
`p50/p95` включают только `TrainStep`-часть эпохи; evaluation исключён.

| Сценарий | Политика | Exact p50 / p95, мс | Accelerated p50 / p95, мс | p50 выигрыш | Coverage p50 | Δ val accuracy | Δ val loss |
|---|---|---:|---:|---:|---:|---:|---:|
| Iris Dense | exact gate | 0.115 / 0.158 | 0.104 / 0.153 | шум 9.1% | 100% | 0.00 п.п. | 0.0% |
| Titanic Dense | exact gate | 0.511 / 0.734 | 0.495 / 0.617 | шум 3.1% | 100% | 0.00 п.п. | 0.0% |
| Car Dense 8→32→16→2 | selective + suffix freeze | 4.830 / 5.677 | 3.769 / 5.504 | 22.0% | 90.7% | −0.35 п.п. | +22.7% |
| MNIST MLP 784→16→10 | selective + head freeze | 121.473 / 140.201 | 58.085 / 109.991 | 52.2% | 90.1% | −1.04 п.п. | +17.9% |
| MNIST Conv 4ch→16→10 | selective + suffix/head freeze | 457.702 / 490.633 | 232.459 / 427.865 | 49.2% | 90.1% | +0.45 п.п. | −2.6% |

Все активные кандидаты выдержали quality gate: абсолютная регрессия validation
accuracy не выше 0.15, относительная регрессия validation loss не выше 0.35.
Car остаётся в политике: его loss вырос на 22.7%, но accuracy изменилась только
на 0.35 процентного пункта, а median epoch ускорилась на 22%.

Воспроизводимый запуск:

```powershell
local_runtime\python\python.exe tests\local_runtime\benchmark_training_epochs.py `
  --compare-algorithmic --runs 1 --epochs 6 --batch-size 128 `
  --output algorithmic_epoch_benchmark.jsonl
```

## Воспроизведение

Из корня репозитория, используя bundled Python:

```powershell
local_runtime\python\python.exe tests\local_runtime\benchmark_training_startup.py `
  --scenario mnist_mlp --path all --repeats 20 `
  --output "$env:TEMP\neuralese-mnist-mlp.jsonl"
```

Сценарии startup benchmark: `iris_dense`, `titanic_dense`, `mnist_mlp`,
`mnist_conv`. Пути:
`cold`, `warm`, `hot`, `all`. JSONL содержит каждую попытку и summary p50/p95;
выбросы сохраняются. ORT может печатать собственные сообщения в терминал, но
файл `--output` содержит только чистый JSONL.

Python benchmark не измеряет Godot frame time напрямую. UI-side контракт
проверяется Godot-тестами: warm-up и TCP polling не блокируют `_ready`/кадр, а
PREPARE выполняется в worker process. Для platform-specific frame pacing нужен
отдельный capture profiler на целевом четырёхпоточном ноутбуке.

## Rollback switches

В `scripts/fully_local_config.gd`:

- `RESIDENT_TRAINING_WORKER = false` — полностью отключить worker;
- `RESIDENT_TRAINING_FALLBACK = true` — оставить one-shot fallback;
- `TRAINING_PREPARE_DEBOUNCE_S` — задержка после изменения графа;
- `TRAINING_PROGRESS_HZ` — частота batch progress;
- `TRAINING_USER_DATASET_CACHE_MIB` — LRU-бюджет пользовательских массивов.

## Native sidecar

Native backend не активирован. Bundled `onnxruntime-training-cpu` wheel содержит
Python extension и `onnxruntime_providers_shared.dll`, но не содержит публичные
C/C++ headers, import library и отдельную ORT DLL с Training C API. Поэтому
собрать и проверить sidecar из этого runtime невозможно; linking к Python
extension был бы неподдерживаемым и хрупким решением.

Для native backend нужна воспроизводимая custom ORT build с training API,
`onnxruntime_training_c_api.h`, `onnxruntime_cxx_api.h`, shared library и import
library одной версии. До появления такого SDK Python prepared path остаётся
основным: он уже выдерживает целевой hot p95 <= 50 мс. Встраивать непроверенный
native loader в release нельзя, потому что это ухудшило бы crash isolation и
fallback correctness.
