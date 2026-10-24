# Ручной QA Windows-релиза

Ручной QA выполняется только для уже опубликованного pre-release. Проверяющий не пересобирает installer и скачивает `Neuralese-Setup.exe` и `latest.json` из одного тега. Promotion запрещён без валидного `qa-report.json`.

## Подготовка

1. Использовать чистые Windows 10 и Windows 11 VM без прав администратора.
2. Скачать assets из pre-release `v<version>`.
3. Проверить `Neuralese-Setup.exe` командой `Get-FileHash -Algorithm SHA256` и сравнить с `latest.json`.
4. Установить предыдущую stable-версию в `%LOCALAPPDATA%\Programs\Neuralese`.
5. Создать тестовый проект, dataset и изменение настроек для проверки сохранности данных.

## Визуальная матрица

Проверить каждый применимый режим:

- 1366x768, scaling 100%.
- 1920x1080, scaling 100%.
- 1920x1080, scaling 125%.
- 2560x1440, scaling 150%.
- Короткие русские release notes.
- Длинные русские release notes со scrolling.
- Английский fallback.
- Progress: 0%, 1%, 50%, 99%, 100%.
- Optional, mandatory и error/retry actions.
- Keyboard focus, Escape policy и HTTPS-ссылка.

В каждом режиме не должно быть обрезанного текста, наложений, скачков размера окна, нечитаемых цветов, зависшего progress, неверного focus или кнопок за границами окна.

## Семантическая матрица

- Текущая версия: окно обновления не появляется.
- Старая версия -> новая optional: обновление и relaunch работают.
- Старая версия -> новая optional: Continue запускает старую версию без installer.
- Старая версия -> новая mandatory: Continue отсутствует.
- Offline и timeout: установленная версия продолжает запускаться.
- 404 manifest/installer: installer не запускается.
- Неверный размер и SHA-256: installer не запускается.
- Обрыв на 10%, 50% и 99%: Retry безопасно начинает новую попытку.
- Путь с пробелами и кириллицей: обновление успешно.
- Non-admin user: обновление работает под LocalAppData.
- Недостаток диска: старая установка остаётся рабочей.
- Два updater-процесса: только один владеет lock.
- Ошибка до swap: запускается старая версия.
- Ошибка после swap: rollback восстанавливает старую версию.
- Новая версия без health marker: rollback восстанавливает старую версию.
- Успех: проекты, datasets, settings, shortcuts и uninstall сохранены.

## Evidence

Нужны минимум четыре screenshot или video URL через HTTPS:

- Release notes до загрузки.
- Progress примерно 50%.
- Ошибка и Retry.
- Успешные 100% перед установкой или relaunch новой версии.

## QA report

Создать `qa-report.json` строго такого формата:

```json
{
  "schema_version": 1,
  "version": "1.0.8",
  "installer_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "builder_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "setup_commit_sha": "cccccccccccccccccccccccccccccccccccccccc",
  "tester": "Lyamon4",
  "tested_at": "2026-07-17T20:00:00Z",
  "windows_versions": ["Windows 10", "Windows 11"],
  "checks": {
    "visual_layout": true,
    "release_notes": true,
    "progress_states": true,
    "optional_update": true,
    "mandatory_update": true,
    "network_failures": true,
    "checksum_rejection": true,
    "rollback": true,
    "user_data_preserved": true,
    "shortcuts_and_uninstall": true
  },
  "evidence": ["https://github.com/hex358/neuralese-builder/issues/3"]
}
```

Проверить и загрузить отчёт:

```powershell
python tools\release\validate_qa_report.py `
  --report qa-report.json `
  --expected-version 1.0.8 `
  --expected-installer-sha256 <sha256> `
  --expected-builder-commit-sha <builder-sha> `
  --expected-setup-commit-sha <setup-sha>

gh release upload v1.0.8 qa-report.json --repo hex358/neuralese-builder --clobber
```

Изменять `Neuralese-Setup.exe` или `latest.json` после QA запрещено. При изменении bytes кандидат создаётся заново и весь QA повторяется.
