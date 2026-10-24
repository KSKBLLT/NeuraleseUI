# Small offline language dependencies

Shipped files, loaded directly from this directory. No package installation,
network request, Hugging Face Hub, Torch or Transformers is required.

- Tokenizers 0.22.2: official CPython abi3 Windows x64 / macOS arm64 wheels.
- Jinja2 3.1.6: official pure Python wheel.
- MarkupSafe 3.0.3: official Python implementation; optional accelerator omitted.

Upstream license files and METADATA accompany each package. `manifest.json`
records wheel and extracted-file SHA-256 hashes. Only the selected platform
and common files are copied into an export (Windows: approximately 8 MB).

Reproduce as a maintainer using official wheels and
`tools/language_models/vendor_dependencies.py --wheels <download-directory>`.
This tool is not part of application startup. The runtime uses the offline
`Tokenizer.from_file` interface; optional Hub-based APIs are not provided.
