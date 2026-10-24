# Windows release runbook

## Один раз в настройках GitHub

1. Защитить `main` в `neuralese-builder` и `neuralese-setup` обязательными PR checks.
2. Создать environment `production` в `neuralese-builder`.
3. Добавить минимум одного required reviewer для `production` и запретить self-review, если настройки организации это позволяют.
4. Разрешить Actions только необходимые read/write permissions. Release workflow получает `contents: write`, обычный CI только `contents: read`.

## Обновление Setup lock

Сначала смёржить и проверить изменения `neuralese-setup`. Затем взять SHA именно из защищённого `main`:

```powershell
$setupSha = gh api repos/hex358/neuralese-setup/commits/main --jq .sha
if ($setupSha -notmatch '^[0-9a-f]{40}$') { throw "Invalid setup SHA" }
```

Записать SHA в `release/setup-lock.json` отдельным PR. Candidate workflow дополнительно проверит, что SHA является предком `neuralese-setup/main`; локальный или непроверенный commit не соберётся.

## Выпуск кандидата

1. Обновить `application/config/version` в `project.godot`.
2. Добавить `release-notes/<version>/ru.md`; `en.md` и `kz.md` необязательны.
3. Смёржить изменения в `main` с зелёными checks.
4. Запустить workflow **Release Windows Candidate**, указав version и mandatory.
5. Workflow повторно запускает Python, Godot и Setup tests, собирает полный installer и создаёт pre-release.
6. Убедиться, что stable `/releases/latest/download/latest.json` не указывает на кандидата.

Runtime для CI восстанавливается из versioned `runtime_payload/windows-x64-runtime.zip` после обязательной SHA-проверки. Исходная локальная Python-среда не загружается в CI и не является скрытой зависимостью сборки.

## Проверка и promotion

1. Выполнить [ручной QA](windows-release-manual-qa.md) на Windows 10 и Windows 11.
2. Загрузить валидный `qa-report.json` в тот же pre-release.
3. Запустить workflow **Promote Windows Release** с той же version.
4. Verify job проверяет release state, историю `main`, required checks, installer, manifest и QA report.
5. Required reviewer подтверждает environment `production`.
6. Promotion меняет только флаги существующего release на stable/latest. Сборка не выполняется.
7. Workflow повторно скачивает production manifest и installer и сверяет их bytes.
8. Проверить обновление с предыдущей stable-версии на отдельной Windows VM.

## Сбой до promotion

Удалить невалидный pre-release и tag, исправить код и создать новый кандидат. Не заменять assets у уже проверенного кандидата.

## Сбой после promotion

1. Немедленно снять плохой release с `latest` для клиентов, которые ещё не обновились.
2. Вернуть предыдущий исправный release в `latest`, если он совместим.
3. Для уже обновившихся клиентов выпустить исправление с большей версией.
4. Автоматический downgrade запрещён: он может нарушить формат проектов и пользовательских данных.
5. Не удалять предыдущий release и evidence до завершения расследования.

Code signing пока не реализован. SHA-256 защищает целостность скачанных bytes, но не заменяет Authenticode и доверенную подпись издателя.
