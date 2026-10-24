# Release notes

Для каждой версии создаётся отдельная папка:

```text
release-notes/
  1.0.8/
    ru.md   # обязательно
    en.md   # необязательно
    kz.md   # необязательно
```

Файлы содержат Markdown, который показывается пользователю перед установкой обновления. `ru.md` должен существовать и содержать текст. Если добавлены `en.md` или `kz.md`, они тоже не должны быть пустыми.

`latest.json` нельзя редактировать вручную. Его создаёт `tools/release/build_release_manifest.py`: скрипт читает заметки, вычисляет размер и SHA-256 готового `Neuralese-Setup.exe`, проверяет URL релиза и записывает manifest атомарно.

Пример:

```bash
python tools/release/build_release_manifest.py \
  --version 1.0.8 \
  --asset Neuralese-Setup.exe \
  --asset-url https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe \
  --notes-dir release-notes/1.0.8 \
  --published-at 2026-07-16T18:30:00Z \
  --builder-commit-sha 0123456789012345678901234567890123456789 \
  --setup-commit-sha 0123456789012345678901234567890123456789 \
  --output latest.json
```

Флаг `--mandatory` помечает обновление обязательным. Без него пользователь может продолжить запуск старой версии.
