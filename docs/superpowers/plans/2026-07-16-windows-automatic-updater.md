# План реализации автоматического обновления Neuralese для Windows

**Цель:** сделать Windows-first обновление Neuralese, при котором GitHub Release является источником версии и release notes, приложение при запуске автоматически скачивает полный установщик с прогрессом, проверяет его и передаёт установку существующему `neuralese-setup`.

**Архитектура:** release-candidate workflow собирает полный `Neuralese-Setup.exe`, создаёт `latest.json` и публикует GitHub pre-release, который не виден production-клиентам. После автоматических тестов и ручного визуального/семантического QA отдельный workflow с защищённым `production` environment переводит те же проверенные bytes в stable без повторной сборки. Neuralese загружает stable `latest.json`, показывает release notes, скачивает установщик в `user://updates`, проверяет размер и SHA-256, запускает silent updater и подтверждает здоровье новой версии до удаления backup.

**Стек:** Godot 4.7.1/GDScript, Rust + Slint (`hex358/neuralese-setup`), PowerShell, Python 3.11, GitHub Actions, GitHub Releases.

## Статус реализации на 2026-07-17

- Клиент, streaming download, health acknowledgement и atomic Setup updater реализованы и покрыты unit/integration тестами.
- PR CI, release-candidate workflow, строгий QA report и защищённый promotion workflow реализованы.
- Windows manual QA и реальный promotion не выполнялись: для них нужен собранный pre-release и Windows 10/11 VM.
- `release/setup-lock.json` намеренно указывает на проверенный Setup commit `39aec8b6080e4187e76deb97d664014c725dfa83`. Candidate workflow останется fail-closed, пока этот commit не будет смёржен в `hex358/neuralese-setup/main`; после squash/merge lock нужно обновить на фактический SHA защищённого `main`.
- GitHub branch protection и required reviewer для environment `production` настраиваются владельцем репозитория по `docs/windows-release-runbook.md`.

## Ограничения первого этапа

- Поддерживается только Windows x86_64.
- macOS и Linux не получают установочные URL до появления проверенных сборок.
- Приложение не содержит GitHub-токенов и не обращается к GitHub API.
- Репозиторий и release assets должны оставаться публичными.
- Source of truth для release notes — Markdown-файлы в `release-notes/<version>/`; workflow копирует их и в GitHub Release, и в `latest.json`.
- Первая сборка всегда становится pre-release. До ручного promotion `/releases/latest/download/latest.json` ведёт на предыдущий исправный stable-релиз.
- Production promotion не пересобирает installer: публикуются ровно те bytes, которые прошли автоматические и ручные проверки.
- В GitHub repository settings создаётся environment `production` с обязательным reviewer.
- Все сторонние GitHub Actions и `neuralese-setup` checkout фиксируются по полному commit SHA, а не по `main` или плавающему tag.
- Release manifest содержит `builder_commit_sha` и `setup_commit_sha`; promotion сверяет их с протестированным кандидатом.
- Скачивается полный `Neuralese-Setup.exe`, а не только `Neuralese.exe`, потому что релиз может менять DLL, GDExtension и локальный runtime.
- Пакет всегда проверяется по `size_bytes` и SHA-256 до запуска.
- SHA-256 обеспечивает целостность, но не заменяет Windows code signing. Подпись установщика является отдельным release-hardening этапом после получения сертификата.
- При отсутствии интернета приложение продолжает запуск текущей версии.
- Необязательное обновление можно пропустить; обязательное позволяет только повторить загрузку или закрыть приложение.
- Обновление не запускается из Godot Editor.

## Итоговый пользовательский flow

```text
Запуск Neuralese
  -> GET latest.json
  -> актуальная версия: обычный запуск
  -> новая версия: окно с release notes
  -> автоматическая загрузка + progress bar
  -> проверка размера и SHA-256
  -> запуск Neuralese-Setup.exe --silent-update
  -> Neuralese закрывается
  -> installer ждёт завершения старого PID
  -> обновляет полный payload
  -> запускает новую Neuralese.exe
```

## Контракт `latest.json`

```json
{
  "schema_version": 1,
  "version": "1.0.8",
  "mandatory": false,
  "published_at": "2026-07-16T18:30:00Z",
  "builder_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "setup_commit_sha": "cccccccccccccccccccccccccccccccccccccccc",
  "notes_markdown": {
    "ru": "**Что нового**\n\n- Ускорена загрузка\n- Исправлены ошибки Axon",
    "en": "**What's new**\n\n- Faster startup\n- Axon fixes"
  },
  "downloads": {
    "windows": {
      "url": "https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe",
      "size_bytes": 125829120,
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}
```

## Карта файлов

### `hex358/neuralese-builder`

- Изменить `project.godot` — единая локальная версия приложения.
- Создать `scripts/update_manifest.gd` — валидация и нормализация `latest.json`.
- Изменить `scripts/update_policy.gd` — сравнение локальной и опубликованной версий.
- Создать `scripts/update_download.gd` — потоковая запись, прогресс, размер и SHA-256.
- Создать `scripts/update_health.gd` — подтверждение успешного запуска новой версии.
- Изменить `scripts/update_state.gd` — state machine и запуск installer.
- Изменить `scripts/dialog_spec.gd` — необязательная progress-конфигурация.
- Изменить `scripts/multipurpose_dialog.gd` — публичное обновление progress/status/actions.
- Изменить `scenes/multipurpose_dialog.tscn` — скрываемый progress-блок.
- Создать `tools/release/build_release_manifest.py` — генерация `latest.json`.
- Создать `tests/release/test_build_release_manifest.py` — тест генератора.
- Создать `release-notes/README.md` — формат заметок к релизу.
- Создать `.github/workflows/release-windows.yml` — сборка и публикация pre-release кандидата.
- Создать `.github/workflows/promote-windows-release.yml` — проверка кандидата и promotion в stable.
- Создать `.github/workflows/test-updater.yml` — автоматические PR checks клиента.
- Создать `.github/CODEOWNERS` и `release/setup-lock.json` — контролируемое обновление installer dependency.
- Создать `tests/godot/test_update_manifest.gd`.
- Создать `tests/godot/test_update_download.gd`.
- Создать `tests/godot/test_update_health.gd`.
- Изменить `tests/godot/test_update_dialog_spec.gd`.
- Создать `tests/godot/test_update_flow.gd`.
- Создать `tests/integration/update_fixture_server.py`.
- Изменить `tests/godot/run_all.sh`.
- Создать `docs/windows-release-runbook.md`.
- Создать `docs/windows-release-manual-qa.md` — визуальный и семантический чек-лист.
- Создать `tools/release/validate_qa_report.py` и `tests/release/test_validate_qa_report.py`.

### `hex358/neuralese-setup`

- Изменить `src-tauri/Cargo.toml` — CLI parsing и Windows process APIs.
- Создать `src-tauri/src/cli.rs` — аргументы обычной установки и silent update.
- Создать `src-tauri/src/update.rs` — ожидание PID, staging, backup, swap и rollback.
- Изменить `src-tauri/src/main.rs` — выбор GUI install или silent-update flow.
- Изменить `build.ps1` и `build-installer.ps1` — передача версии приложения.
- Добавить Rust unit-тесты в `src-tauri/src/cli.rs` и `src-tauri/src/update.rs`.
- Изменить `README.md` — документировать updater CLI.
- Создать `.github/workflows/ci.yml` — Rust format, clippy, unit и Windows integration checks.

---

### Задача 1: единый источник локальной версии

**Файлы:**

- Изменить: `project.godot`
- Изменить: `scripts/update_state.gd`
- Создать: `tests/godot/test_update_version.gd`
- Изменить: `tests/godot/run_all.sh`

**Интерфейсы:**

- Локальная версия читается через `ProjectSettings.get_setting("application/config/version", "0.0.0")`.
- User-Agent продолжает использовать то же значение.
- `UpdateManager` больше не содержит `LOCAL_VERSION`.

- [ ] Добавить в `[application]` файла `project.godot`:

```ini
config/version="1.0.8"
```

- [ ] Добавить падающий тест нового источника версии:

```gdscript
extends SceneTree

const UpdateManagerClass := preload("res://scripts/update_state.gd")

func _initialize() -> void:
    var manager = UpdateManagerClass.new()
    var actual: String = manager._local_version()
    if actual != "1.0.8":
        push_error("expected project version 1.0.8, got %s" % actual)
        quit(1)
        return
    print("PASS test_update_version")
    quit(0)
```

- [ ] Запустить тест и подтвердить падение до удаления `LOCAL_VERSION`:

```powershell
godot --headless --path . --quit-after 300 --script tests/godot/test_update_version.gd
```

Ожидается: FAIL, потому что `_local_version()` ещё не существует.

- [ ] Заменить в `scripts/update_state.gd` константу на функцию:

```gdscript
func _local_version() -> String:
    return str(ProjectSettings.get_setting("application/config/version", "0.0.0")).strip_edges()
```

- [ ] Передавать версию и платформу при запросе manifest:

```gdscript
const RELEASE_MANIFEST_URL := "https://github.com/hex358/neuralese-builder/releases/latest/download/latest.json"

var response = await web.GET(RELEASE_MANIFEST_URL)
```

- [ ] Добавить `test_update_version.gd` в `tests/godot/run_all.sh`, запустить `test_update_version.gd` и существующий `test_update_policy.gd`.

- [ ] Commit:

```bash
git add project.godot scripts/update_state.gd tests/godot/test_update_version.gd tests/godot/run_all.sh
git commit -m "refactor: use project version for updates"
```

---

### Задача 2: строгий парсер release manifest

**Файлы:**

- Создать: `scripts/update_manifest.gd`
- Изменить: `scripts/update_policy.gd`
- Создать: `tests/godot/test_update_manifest.gd`
- Изменить: `tests/godot/run_all.sh`

**Интерфейсы:**

- `UpdateManifest.parse(payload: Variant) -> Dictionary`
- Успех возвращает нормализованный manifest.
- Ошибка возвращает `{}` и никогда не подставляет небезопасный URL.

- [ ] Создать тесты для полного manifest, отсутствующего `size_bytes`, неверного SHA-256, `javascript:` URL, неизвестного `schema_version`, пустых notes и лишних полей.

Минимальный ожидаемый результат:

```gdscript
var parsed := UpdateManifest.parse(valid_payload)
_expect_equal(parsed["version"], "1.0.8", "version")
_expect_equal(parsed["mandatory"], false, "mandatory")
_expect_equal(parsed["downloads"]["windows"]["size_bytes"], 125829120, "size")
_expect_equal(UpdateManifest.parse({"schema_version": 2}), {}, "unknown schema")
```

- [ ] Запустить тест и подтвердить падение из-за отсутствующего `update_manifest.gd`.

- [ ] Реализовать `UpdateManifest` со следующими правилами:

```gdscript
extends RefCounted
class_name UpdateManifest

const SCHEMA_VERSION := 1
const MIN_PACKAGE_SIZE := 1024 * 1024
const MAX_PACKAGE_SIZE := 4 * 1024 * 1024 * 1024

static func parse(payload: Variant) -> Dictionary:
    if not payload is Dictionary:
        return {}
    if int(payload.get("schema_version", 0)) != SCHEMA_VERSION:
        return {}
    var version := str(payload.get("version", "")).strip_edges()
    if not UpdatePolicy.is_valid_version(version):
        return {}
    var package := _parse_windows_package(payload.get("downloads", {}))
    var notes := _parse_notes(payload.get("notes_markdown", ""))
    var builder_sha := _parse_commit_sha(payload.get("builder_commit_sha", ""))
    var setup_sha := _parse_commit_sha(payload.get("setup_commit_sha", ""))
    if package.is_empty() or notes.is_empty() or builder_sha.is_empty() or setup_sha.is_empty():
        return {}
    return {
        "schema_version": SCHEMA_VERSION,
        "version": version,
        "mandatory": payload.get("mandatory", false) == true,
        "published_at": str(payload.get("published_at", "")),
        "builder_commit_sha": builder_sha,
        "setup_commit_sha": setup_sha,
        "notes_markdown": notes,
        "downloads": {"windows": package},
    }
```

- [ ] В `_parse_windows_package()` разрешить только HTTPS, положительный размер в заданных границах и 64 lowercase hex-символа SHA-256.

- [ ] В `_parse_notes()` принимать непустую строку или Dictionary с непустыми строковыми значениями `ru`, `en`, `kz`. Manifest без единого текста release notes отклонять.

- [ ] В `_parse_commit_sha()` принимать только 40 lowercase hex-символов. Пустой или сокращённый SHA отклоняет весь manifest.

- [ ] Добавить тест в `tests/godot/run_all.sh`, запустить весь Godot-набор и убедиться, что старые manifest-форматы больше не проходят новый parser случайно.

- [ ] Commit:

```bash
git add scripts/update_manifest.gd tests/godot/test_update_manifest.gd tests/godot/run_all.sh scripts/update_policy.gd
git commit -m "feat: validate update release manifests"
```

---

### Задача 3: release notes и генератор `latest.json`

**Файлы:**

- Создать: `tools/release/build_release_manifest.py`
- Создать: `tests/release/test_build_release_manifest.py`
- Создать: `release-notes/README.md`

**Интерфейсы:**

- CLI принимает `--version`, `--mandatory`, `--asset`, `--asset-url`, `--notes-dir`, `--published-at`, `--builder-commit-sha`, `--setup-commit-sha`, `--output`.
- `ru.md` обязателен; `en.md` и `kz.md` необязательны.
- Скрипт вычисляет SHA-256 и размер реального файла, а не принимает их строками.

- [ ] Написать pytest, создающий временный installer и notes:

```python
def test_builds_manifest_from_real_asset(tmp_path):
    asset = tmp_path / "Neuralese-Setup.exe"
    asset_bytes = b"MZ" + (b"\0" * (1024 * 1024))
    asset.write_bytes(asset_bytes)
    notes = tmp_path / "notes"
    notes.mkdir()
    (notes / "ru.md").write_text("**Что нового**\n\n- Исправления", encoding="utf-8")

    manifest = build_manifest(
        version="1.0.8",
        mandatory=False,
        asset=asset,
        asset_url="https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe",
        notes_dir=notes,
        published_at="2026-07-16T18:30:00Z",
        builder_commit_sha="b" * 40,
        setup_commit_sha="c" * 40,
    )

    assert manifest["schema_version"] == 1
    assert manifest["builder_commit_sha"] == "b" * 40
    assert manifest["setup_commit_sha"] == "c" * 40
    assert manifest["downloads"]["windows"]["size_bytes"] == len(asset_bytes)
    assert len(manifest["downloads"]["windows"]["sha256"]) == 64
    assert manifest["notes_markdown"]["ru"].startswith("**Что нового**")
```

- [ ] Запустить `python -m pytest tests/release/test_build_release_manifest.py -v` и подтвердить падение.

- [ ] Реализовать generator через стандартную библиотеку Python: `argparse`, `hashlib`, `json`, `pathlib`, `datetime`. Не добавлять runtime dependencies.

- [ ] Генерировать JSON с `ensure_ascii=False`, `indent=2` и завершающим newline.

- [ ] Отклонять версии не вида `N.N.N`, пустой `ru.md`, asset меньше 1 МБ и URL не на `https://github.com/hex358/neuralese-builder/releases/download/`.

- [ ] Описать процесс заметок в `release-notes/README.md`:

```text
release-notes/
  1.0.8/
    ru.md   # required
    en.md   # optional
    kz.md   # optional
```

- [ ] Запустить pytest и проверить детерминированный JSON snapshot.

- [ ] Commit:

```bash
git add tools/release/build_release_manifest.py tests/release/test_build_release_manifest.py release-notes/README.md
git commit -m "feat: generate release manifests from notes"
```

---

### Задача 4: progress-блок универсального окна

**Файлы:**

- Изменить: `scenes/multipurpose_dialog.tscn`
- Изменить: `scripts/dialog_spec.gd`
- Изменить: `scripts/multipurpose_dialog.gd`
- Изменить: `tests/godot/test_dialog_spec.gd`
- Изменить: `tests/godot/test_multipurpose_dialog.gd`

**Интерфейсы:**

- Dialog spec получает необязательный `progress`.
- `MultipurposeDialog.set_progress(value: float, status: String, detail: String) -> void`.
- `MultipurposeDialog.set_actions(actions: Array[Dictionary]) -> void`.
- `DialogSpec.normalize_buttons(value: Variant, language: String) -> Array[Dictionary]` становится публичной функцией для динамической смены actions.
- Внутри универсального окна нет проверки версий, URL или файлов.

- [ ] Добавить падающие тесты:

```gdscript
var dialog = DIALOG_SCENE.instantiate()
dialog.configure({
    "id": "download",
    "title": "Update",
    "progress": {"visible": true, "value": 0.0, "status": "Downloading", "detail": "0 MB"},
    "buttons": [],
}, "en", Vector2(1280, 720))
root.add_child(dialog)
dialog.set_progress(42.5, "Downloading", "51 of 120 MB")
_expect_equal(dialog.get_progress_value(), 42.5, "dynamic progress")
```

- [ ] Запустить scene-тест и подтвердить падение из-за отсутствующих progress nodes/methods.

- [ ] Добавить в сцену скрытый `VBoxContainer` с именем `ProgressSection`, `Label Status`, `ProgressBar Bar`, `Label Detail`. Использовать текущие шрифты и цвета окна; не создавать отдельную update-сцену.

- [ ] Нормализовать progress:

```gdscript
"progress": {
    "visible": progress.get("visible", false) == true,
    "value": clampf(float(progress.get("value", 0.0)), 0.0, 100.0),
    "status": localize(progress.get("status", ""), language),
    "detail": localize(progress.get("detail", ""), language),
}
```

- [ ] Реализовать публичное обновление progress без повторной конфигурации всего окна и без пересоздания сцены.

- [ ] Реализовать `set_actions()` через существующий `_rebuild_actions()`, сохраняя проверку уникальных IDs.

- [ ] Запустить `test_dialog_spec.gd`, `test_multipurpose_dialog.gd` и render smoke.

- [ ] Commit:

```bash
git add scenes/multipurpose_dialog.tscn scripts/dialog_spec.gd scripts/multipurpose_dialog.gd tests/godot/test_dialog_spec.gd tests/godot/test_multipurpose_dialog.gd
git commit -m "feat: add reusable dialog progress state"
```

---

### Задача 5: потоковый download engine

**Файлы:**

- Создать: `scripts/update_download.gd`
- Создать: `tests/godot/test_update_download.gd`
- Изменить: `tests/godot/run_all.sh`

**Интерфейсы:**

- `UpdateDownload.download(handle: RefCounted, package: Dictionary, destination: String) -> Dictionary`.
- Сигнал `progress(downloaded_bytes: int, total_bytes: int, percent: float)`.
- Результат успеха: `{"ok": true, "path": destination}`.
- Результат ошибки: `{"ok": false, "error": "network|size|checksum|io"}`.

- [ ] Создать fake request handle с сигналами `on_chunk` и `completed`; тест должен отправлять три chunk и проверять монотонный progress.

- [ ] Добавить тесты размера, SHA mismatch, network error и удаления повреждённого `.part`.

- [ ] Запустить тест и подтвердить падение до появления класса.

- [ ] Реализовать запись только в `<destination>.part`:

```gdscript
signal progress(downloaded_bytes: int, total_bytes: int, percent: float)

func _emit_progress(downloaded: int, total: int) -> void:
    var percent := clampf((float(downloaded) / float(total)) * 100.0, 0.0, 100.0)
    progress.emit(downloaded, total, percent)
```

- [ ] После `completed.ok` закрыть файл, сравнить точный размер, затем `FileAccess.get_sha256(part_path)`.

- [ ] Прервать download сразу, если получено больше `size_bytes`; не ждать завершения потенциально бесконечного ответа.

- [ ] Принимать installer URL только с host `github.com`, path prefix `/hex358/neuralese-builder/releases/download/` и filename `Neuralese-Setup.exe`.

- [ ] Ограничить автоматические повторы тремя попытками с задержками 1, 2 и 4 секунды. После третьей ошибки показать Retry пользователю; бесконечный retry loop запрещён.

- [ ] Только после обеих проверок удалить старый destination и атомарно переименовать `.part` в destination.

- [ ] На старте удалять только собственные `.part` старше 24 часов внутри `user://updates`; не выполнять рекурсивную очистку произвольных директорий.

- [ ] Не использовать количество chunk как прогресс: chunk имеют разный размер.

- [ ] Добавить форматирование объёма в отдельную pure-функцию `format_bytes(value: int) -> String` и тесты `0 B`, `1.0 MB`, `120.0 MB`.

- [ ] Запустить тесты и commit:

```bash
git add scripts/update_download.gd tests/godot/test_update_download.gd tests/godot/run_all.sh
git commit -m "feat: stream and verify update downloads"
```

---

### Задача 6: silent-update режим `neuralese-setup`

**Репозиторий:** `hex358/neuralese-setup`

**Файлы:**

- Изменить: `src-tauri/Cargo.toml`
- Создать: `src-tauri/src/cli.rs`
- Создать: `src-tauri/src/update.rs`
- Изменить: `src-tauri/src/main.rs`
- Изменить: `build.ps1`
- Изменить: `build-installer.ps1`
- Изменить: `README.md`

**Интерфейсы:**

```text
Neuralese-Setup.exe --silent-update \
  --install-dir "C:\Users\student\AppData\Local\Programs\Neuralese" \
  --wait-pid 1234 \
  --launch-after-update
```

- [ ] Добавить `clap` и Windows process wait features:

```toml
clap = { version = "4", features = ["derive"] }
uuid = { version = "1", features = ["v4"] }

[target.'cfg(windows)'.dependencies]
windows-sys = { version = "0.59", features = [
  "Win32_Foundation",
  "Win32_System_Threading",
  "Win32_UI_WindowsAndMessaging"
] }
```

- [ ] В `cli.rs` определить типизированные аргументы и тесты отсутствующего `--install-dir`, нечислового PID и обычного GUI-запуска без flags.

- [ ] В `update.rs` выделить функции:

```rust
pub struct SilentUpdateOptions {
    pub install_dir: PathBuf,
    pub wait_pid: u32,
    pub launch_after_update: bool,
}

pub fn run_silent_update(options: SilentUpdateOptions) -> Result<(), String>;
fn wait_for_process_exit(pid: u32, timeout: Duration) -> Result<(), String>;
fn stage_payload(stage_dir: &Path) -> Result<ExtractedPayload, String>;
fn swap_installation(install_dir: &Path, stage_dir: &Path, backup_dir: &Path) -> Result<(), String>;
fn rollback_installation(install_dir: &Path, backup_dir: &Path) -> Result<(), String>;
fn wait_for_health(child: &mut Child, health_file: &Path, token: &str, timeout: Duration) -> Result<(), String>;
```

- [ ] Silent updater должен сначала проверить `.neuralese-install-marker`; случайная непомеченная директория отклоняется.

- [ ] Installer ждёт старый PID максимум 60 секунд. Timeout не изменяет установленную версию.

- [ ] До staging создать lock через `OpenOptions::new().write(true).create_new(true)`. Если живой updater уже владеет lock, второй процесс завершается без изменения файлов. Stale lock удаляется только после проверки записанного PID.

- [ ] До распаковки проверить свободное место: доступно не меньше `2 * embedded_payload_size + current_install_size`. При недостатке места старая установка остаётся нетронутой.

- [ ] Payload распаковывается в sibling staging directory, проверяется наличие `Neuralese.exe`, затем текущая установка переименовывается в backup и staging становится новой установкой.

- [ ] После swap запустить новую Neuralese с `--post-update-health-file=<path>` и `--post-update-token=<uuid-v4>`. Не удалять backup до подтверждения token, version и PID в health-файле.

- [ ] Health-файл создавать как sibling скачанного installer: `<installer_dir>/health/<uuid-v4>.json`. Installer не принимает health path извне, а приложение разрешает запись только в свой `user://updates/health`.

- [ ] Если новая версия завершилась раньше health-check, не создала marker за 45 секунд или записала неверный token/version, завершить новый процесс, восстановить backup и запустить старую версию.

- [ ] Если swap, запуск или health-check завершается ошибкой, восстановить backup. Rollback должен быть идемпотентным: повторный вызов не удаляет единственную рабочую копию.

- [ ] Staging и backup должны быть sibling directories того же тома, чтобы directory rename оставался атомарным. Нельзя staging-ить в `%TEMP%` и затем копировать поверх работающей установки.

- [ ] Не удалять `user://` данные: они находятся вне install directory.

- [ ] Обычный GUI installer должен продолжить работать без изменений.

- [ ] Добавить fault-injection unit-тесты: ошибка после staging, после backup rename, после install rename, ошибка launch и health timeout. После каждого сценария ровно одна рабочая установка должна содержать старый executable.

- [ ] Добавить `-AppVersion` в PowerShell scripts и передавать `NEURALESE_APP_VERSION`; использовать его в install manifest и Windows uninstall `DisplayVersion` вместо Cargo package version.

- [ ] Запустить:

```powershell
cargo test --manifest-path .\src-tauri\Cargo.toml
cargo check --release --manifest-path .\src-tauri\Cargo.toml
```

Ожидается: все unit-тесты проходят; Windows release target компилируется.

- [ ] Commit в `neuralese-setup`:

```bash
git add src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/src/cli.rs src-tauri/src/update.rs src-tauri/src/main.rs build.ps1 build-installer.ps1 README.md
git commit -m "feat: support silent atomic updates"
```

---

### Задача 7: startup update state machine

**Файлы:**

- Изменить: `scripts/update_state.gd`
- Изменить: `scripts/update_prompt_spec.gd`
- Создать: `scripts/update_health.gd`
- Создать: `tests/godot/test_update_health.gd`
- Создать: `tests/godot/test_update_flow.gd`
- Изменить: `tests/godot/test_update_dialog_spec.gd`
- Изменить: `tests/godot/run_all.sh`

**Интерфейсы:**

```gdscript
enum State {
    IDLE,
    CHECKING,
    DOWNLOADING,
    VERIFYING,
    LAUNCHING_INSTALLER,
    ERROR,
}
```

- [ ] Создать fake manifest request, fake download handle и fake process launcher. Тестировать flow без сети и без запуска `.exe`.

- [ ] Проверить сценарии: актуальная версия, offline, новая optional, новая mandatory, checksum failure, retry, continue и успешный installer launch.

- [ ] При новой версии сразу показать окно с release notes и начать скачивание. Первоначальные buttons:

```gdscript
[
    {"id": "continue", "text": {"ru": "Продолжить без обновления", "en": "Continue without updating"}, "style": "secondary"}
]
```

Для `mandatory=true` первоначальных кнопок нет.

- [ ] Во время загрузки вызывать:

```gdscript
dialog.set_progress(
    percent,
    "Скачивание обновления",
    "%s из %s" % [UpdateDownload.format_bytes(downloaded), UpdateDownload.format_bytes(total)]
)
```

- [ ] При ошибке выставлять Retry + Continue для optional и Retry + Exit для mandatory.

- [ ] После проверки установить status `Установка обновления`, запустить installer:

```gdscript
var args := PackedStringArray([
    "--silent-update",
    "--install-dir", _exe_dir,
    "--wait-pid", str(OS.get_process_id()),
    "--launch-after-update",
])
var pid := OS.create_process(installer_path, args)
if pid <= 0:
    return {"ok": false, "error": "installer_launch"}
get_tree().quit()
return {"ok": true}
```

- [ ] Определять install root не как `_exe_dir`, а поиском `.neuralese-install-marker` от директории executable вверх. Если marker не найден, updater не запускается и optional flow продолжает обычный старт.

- [ ] Реализовать `UpdateHealth.acknowledge_from_command_line()` и вызвать его после создания главного окна и локальных autoloads, но до сетевого login/update flow:

```gdscript
static func acknowledge_from_command_line() -> void:
    var health_file := _argument_value("--post-update-health-file=")
    var token := _argument_value("--post-update-token=")
    if health_file.is_empty() or token.is_empty():
        return
    var payload := {
        "token": token,
        "version": str(ProjectSettings.get_setting("application/config/version", "0.0.0")),
        "pid": OS.get_process_id(),
    }
    _write_json_atomically(health_file, payload)
```

- [ ] Разрешать health path только внутри заранее созданного `user://updates/health` после `ProjectSettings.globalize_path()` и canonical-path проверки. Произвольный путь из command line не записывать.

- [ ] Тестировать: отсутствие args ничего не пишет, неверный путь отклоняется, token/version/PID записываются атомарно, stale marker не принимается installer-ом.

- [ ] Удалить старую логику `update.cmd` и замену только `Neuralese.exe` после прохождения setup integration tests.

- [ ] Не показывать окно, если manifest не загрузился или версия актуальна.

- [ ] Запустить весь Godot test suite и commit:

```bash
git add scripts/update_state.gd scripts/update_prompt_spec.gd scripts/update_health.gd tests/godot/test_update_flow.gd tests/godot/test_update_dialog_spec.gd tests/godot/test_update_health.gd tests/godot/run_all.sh
git commit -m "feat: orchestrate automatic startup updates"
```

---

### Задача 8: GitHub Actions release-candidate pipeline

**Файлы:**

- Создать: `.github/workflows/release-windows.yml`
- Создать: `release/setup-lock.json`
- Создать: `.github/CODEOWNERS`

**Workflow inputs:**

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Release version without v prefix"
        required: true
        type: string
      mandatory:
        description: "Block old clients until update succeeds"
        required: true
        default: false
        type: boolean
```

- [ ] Добавить job `validate` на `windows-latest`: версия должна соответствовать `^[0-9]+\.[0-9]+\.[0-9]+$`, совпадать с `project.godot`, tag `v<version>` и release не должны существовать, `release-notes/<version>/ru.md` должен быть непустым.

- [ ] Pin всех `uses:` в release/test/promotion workflows по полному 40-символьному commit SHA. Плавающие `@main`, `@master` и major tags запрещены для production pipeline.

- [ ] Checkout текущего репозитория и `hex358/neuralese-setup` в поддиректорию `neuralese-setup` на SHA из versioned файла `release/setup-lock.json`. Workflow отклоняет SHA, которого нет в `hex358/neuralese-setup/main`.

- [ ] Добавить CODEOWNERS и branch protection, чтобы изменение setup lock требовало review:

```text
/release/setup-lock.json @hex358 @Lyamon4
/.github/workflows/release-windows.yml @hex358 @Lyamon4
/.github/workflows/promote-windows-release.yml @hex358 @Lyamon4
```

- [ ] После merge одобренного `neuralese-setup` PR получить реальный SHA защищённого `main` и записать его в lock:

```powershell
$setupSha = gh api repos/hex358/neuralese-setup/commits/main --jq .sha
if ($setupSha -notmatch '^[0-9a-f]{40}$') { throw "Invalid setup commit SHA" }
@{
  repository = "hex358/neuralese-setup"
  commit_sha = $setupSha
} | ConvertTo-Json | Set-Content -Encoding UTF8 release/setup-lock.json
```

- [ ] Установить Godot 4.7.1 stable и export templates, Python 3.11 и Rust stable.

- [ ] До production build запустить builder updater tests и полный `cargo test`/`cargo clippy` pinned setup commit. Build запрещён при любом failed check.

- [ ] Собрать production payload существующими скриптами:

```powershell
.\tools\build_pruned.ps1 -ProjectRoot $PWD -Platform windows-x64 -SkipSmokeTest -SkipPayloadZip
.\tools\export_windows_with_runtime.ps1 -ProjectRoot $PWD -GodotExe $env:GODOT_EXE -Output "$env:RUNNER_TEMP\game\Neuralese.exe"
.\tools\prepare_windows_installer_payload.ps1 -ProjectRoot $PWD -GameDir "$env:RUNNER_TEMP\game" -OutputZip "$env:RUNNER_TEMP\game.zip"
```

- [ ] Собрать installer:

```powershell
.\neuralese-setup\build.ps1 `
  -PayloadZip "$env:RUNNER_TEMP\game.zip" `
  -AppName "Neuralese" `
  -AppVersion "${{ inputs.version }}" `
  -GameExeName "Neuralese.exe" `
  -OutputDir "$env:RUNNER_TEMP\release"
```

- [ ] Переименовать выход строго в `Neuralese-Setup.exe` и выполнить smoke-проверки существования, размера больше 10 МБ и PE-сигнатуры `MZ`.

- [ ] Запустить generator `latest.json` с tag-specific asset URL и notes directory.

- [ ] Создать pre-release с tag `v<version>`, используя `release-notes/<version>/ru.md` как body. Не отмечать его latest.

- [ ] Загрузить в pre-release `Neuralese-Setup.exe` и `latest.json`.

- [ ] Скачать оба assets обратно в runner, повторно проверить SHA/size против manifest.

- [ ] Завершить workflow без stable promotion. При ошибке удалить неполный pre-release и tag; предыдущий stable release остаётся latest.

- [ ] Оставить GitHub Artifact с installer, manifest, setup lock и build logs на 14 дней независимо от ручного QA.

- [ ] Добавить concurrency, запрещающий два параллельных production release:

```yaml
concurrency:
  group: neuralese-windows-production-release
  cancel-in-progress: false
```

- [ ] После публикации pre-release проверить, что production URL всё ещё возвращает предыдущую stable-версию:

```text
https://github.com/hex358/neuralese-builder/releases/latest/download/latest.json
```

- [ ] Commit:

```bash
git add .github/workflows/release-windows.yml .github/CODEOWNERS release/setup-lock.json
git commit -m "ci: build Windows release candidates"
```

---

### Задача 9: автоматические unit и integration проверки

**Файлы:**

- Создать в builder: `.github/workflows/test-updater.yml`
- Создать в setup: `.github/workflows/ci.yml`
- Создать: `tests/integration/update_fixture_server.py`
- Создать: `tests/godot/test_update_integration.gd`
- Изменить: `tests/godot/run_all.sh`

- [ ] Fixture server должен отдавать manifest, installer bytes чанками фиксированного размера и режимы 404, disconnect, wrong-size, wrong-sha.

- [ ] Integration test должен проверить, что progress монотонно идёт от значения больше 0 до 100, конечный файл совпадает с fixture и `.part` отсутствует.

- [ ] Проверить, что release notes с `[` и `]` не инжектят BBCode, а HTTPS-ссылки остаются кликабельными.

- [ ] Добавить unit-тесты pure-логики: version comparison, manifest schema, URL allowlist, notes localization, byte formatting, progress clamp, retry limit, install-root marker и health-file validation.

- [ ] Добавить Rust unit-тесты: CLI parsing, lock contention, insufficient disk simulation, zip-slip rejection, staging failure, swap failure, health timeout и rollback idempotency.

- [ ] Добавить Windows integration test, который обновляет временную fake-installation с marker, проверяет backup, запускает fake child health acknowledgement и убеждается, что backup удаляется только после health success.

- [ ] Builder PR workflow запускает Python tests, все Godot updater/dialog tests и `git diff --check`. Setup PR workflow на `windows-latest` запускает:

```powershell
cargo fmt --manifest-path .\src-tauri\Cargo.toml -- --check
cargo clippy --manifest-path .\src-tauri\Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path .\src-tauri\Cargo.toml
cargo check --release --manifest-path .\src-tauri\Cargo.toml
```

- [ ] Защитить `main` обоих репозиториев required checks. Release workflow дополнительно повторяет критические tests, не полагаясь только на старый зелёный PR.

- [ ] Выполнить финальные команды:

```powershell
python -m pytest tests\release -v
$fixture = Start-Process python -ArgumentList "tests\integration\update_fixture_server.py", "--port", "18081" -PassThru
try {
  godot --headless --path . --quit-after 300 --script tests/godot/test_update_integration.gd -- --fixture-url=http://127.0.0.1:18081
} finally {
  Stop-Process -Id $fixture.Id -ErrorAction SilentlyContinue
}
```

```powershell
cargo test --manifest-path .\src-tauri\Cargo.toml
cargo check --release --manifest-path .\src-tauri\Cargo.toml
```

- [ ] Commit документации и integration tests:

```bash
git add .github/workflows/test-updater.yml tests/integration/update_fixture_server.py tests/godot/test_update_integration.gd tests/godot/run_all.sh
git commit -m "test: verify automatic update flow"
```

В `neuralese-setup` выполнить отдельный commit:

```bash
git add .github/workflows/ci.yml
git commit -m "ci: verify installer updates"
```

---

### Задача 10: обязательный ручной QA кандидата

**Файлы:**

- Создать: `docs/windows-release-manual-qa.md`
- Создать: `tools/release/validate_qa_report.py`
- Создать: `tests/release/test_validate_qa_report.py`
- Создать при каждом релизе: `qa-report.json` как asset конкретного pre-release

- [ ] Зафиксировать визуальную матрицу в `docs/windows-release-manual-qa.md`:

```text
1366x768 at 100% scaling
1920x1080 at 100% scaling
1920x1080 at 125% scaling
2560x1440 at 150% scaling
short Russian release notes
long Russian release notes with scrolling
English fallback release notes
progress states 0%, 1%, 50%, 99%, 100%
optional buttons, mandatory buttons and error buttons
keyboard focus, Escape policy and clickable HTTPS link
```

- [ ] Для каждого визуального режима проверить отсутствие обрезанного текста, наложений, скачков размера окна, нечитаемых цветов, зависшего progress, неправильного focus и выхода кнопок за границы.

- [ ] Зафиксировать семантическую матрицу на чистой Windows 10 и Windows 11 VM:

```text
current version: no window
older -> newer optional: update and relaunch
older -> newer optional: continue without update
older -> newer mandatory: no continue action
offline and timeout: old version launches
404 manifest and installer: no execution
wrong size and wrong SHA-256: installer never starts
connection interrupted at 10%, 50%, 99%: retry starts safely
path containing spaces and Cyrillic: update succeeds
non-admin user: update succeeds under LocalAppData
insufficient disk: old version remains intact
two concurrent updater processes: one owns lock, one exits
failure before swap: old version launches
failure after swap: rollback restores old version
new version without health marker: rollback restores old version
successful update: projects, datasets, settings, shortcuts and uninstall remain valid
```

- [ ] Снять минимум четыре screenshot evidence: release notes, середина download, error/retry и успешные 100%. Приложить пути/URLs evidence в QA report.

- [ ] `qa-report.json` должен иметь строгую структуру:

```json
{
  "schema_version": 1,
  "version": "1.0.8",
  "installer_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "builder_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "setup_commit_sha": "cccccccccccccccccccccccccccccccccccccccc",
  "tester": "Lyamon4",
  "tested_at": "2026-07-16T20:00:00Z",
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

- [ ] Реализовать `validate_qa_report.py`: требовать все поля, точное совпадение version/SHA/commit SHAs, обе Windows версии, все checks равны `true` и непустой HTTPS evidence URL.

- [ ] Покрыть validator тестами пропущенного check, `false`, неправильного SHA, другой версии, пустого evidence и валидного отчёта.

- [ ] После ручного QA загрузить report в тот же pre-release без изменения installer или manifest:

```powershell
gh release upload "v1.0.8" qa-report.json --repo hex358/neuralese-builder
```

- [ ] Commit QA tooling и checklist:

```bash
git add docs/windows-release-manual-qa.md tools/release/validate_qa_report.py tests/release/test_validate_qa_report.py
git commit -m "test: require Windows release QA evidence"
```

---

### Задача 11: защищённый promotion в production

**Файлы:**

- Создать: `.github/workflows/promote-windows-release.yml`
- Создать: `docs/windows-release-runbook.md`

- [ ] Настроить GitHub environment `production` с обязательным reviewer. Без approval job не может менять release.

- [ ] Promotion workflow принимает только `version`, скачивает `Neuralese-Setup.exe`, `latest.json` и `qa-report.json` из pre-release `v<version>`.

- [ ] Workflow проверяет, что release является pre-release, не draft, target commit находится в истории `main`, а обязательные GitHub checks этого commit завершились успешно.

- [ ] Сверить фактический installer SHA/size, manifest SHA/size, `builder_commit_sha`, `setup_commit_sha` и все поля QA report. Любое расхождение запрещает promotion.

- [ ] Promotion workflow не запускает Godot export, Rust build или manifest generator.

- [ ] После reviewer approval перевести существующий release в stable без изменения assets:

```powershell
gh release edit "v${{ inputs.version }}" --repo hex358/neuralese-builder --prerelease=false --latest
```

- [ ] Сразу после promotion скачать production `latest.json`, проверить version/SHA и доступность installer. Ошибка помечает workflow failed и требует ручного решения; автоматическое удаление предыдущего release запрещено.

- [ ] В runbook зафиксировать release flow:

```text
1. Обновить application/config/version.
2. Добавить release-notes/<version>/ru.md и переводы.
3. Смёржить изменения в main с зелёными checks.
4. Запустить Release Windows Candidate.
5. Дождаться pre-release и автоматических тестов.
6. Выполнить manual QA на Windows 10/11 и загрузить qa-report.json.
7. Запустить Promote Windows Release.
8. Reviewer проверяет evidence и подтверждает production environment.
9. Проверить stable latest.json, installer и обновление с предыдущей версии.
```

- [ ] Зафиксировать аварийный процесс: снять плохой release с latest для ещё не обновившихся клиентов и немедленно выпустить исправление с большей версией для уже обновившихся; автоматический downgrade запрещён.

- [ ] Commit:

```bash
git add .github/workflows/promote-windows-release.yml docs/windows-release-runbook.md
git commit -m "ci: gate Windows production promotion"
```

---

## Definition of Done

- `application/config/version` является единственной локальной версией клиента.
- Release notes пишутся один раз в Git-репозитории и автоматически попадают в GitHub Release и приложение.
- `latest.json` публикуется только вместе с полностью собранным installer.
- Production-клиенты не видят release candidate до ручного promotion.
- Promotion использует те же installer bytes и не выполняет повторную сборку.
- Builder и setup commit SHAs зафиксированы в manifest и сверены с setup lock/QA report.
- Все Python, Godot и Rust unit/integration checks обязательны для merge и release candidate.
- Ручной визуальный и семантический QA на Windows 10/11 подтверждён валидным `qa-report.json` и evidence.
- Сайт может использовать стабильные GitHub URLs без собственного release backend.
- Neuralese показывает release notes и реальный byte-progress до запуска основной рабочей области.
- Повреждённый или неполный installer никогда не запускается.
- Обновляется полный payload через `neuralese-setup`, а не только Godot executable.
- Ошибка обновления не уничтожает предыдущую рабочую установку.
- Текущая установка сохраняется как backup до health-check новой версии; при timeout или раннем падении выполняется rollback.
- Параллельный запуск двух updater-процессов запрещается lock-файлом.
- Недостаток места, повреждение download, ошибка staging/swap и отсутствие health marker оставляют старую версию запускаемой.
- Optional, mandatory, offline и corrupt-download сценарии покрыты тестами.
- macOS код не добавляется и не имитируется до появления настоящей macOS build/install pipeline.
