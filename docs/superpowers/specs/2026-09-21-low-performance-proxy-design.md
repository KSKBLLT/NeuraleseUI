# Low-performance llvmpipe proxy design

## Goal

Restore the low-end rendering proxy previously used on the `yernar` branch so
the application can be exercised under severe, repeatable render pressure.

## Fixed environment

- WSL2 Ubuntu 24.04.
- WSL virtual machine limited by `C:\Users\Mike\.wslconfig` to 4 processors,
  4 GB RAM, and no swap.
- Mesa Vulkan lavapipe forced through
  `/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`; hardware Vulkan and WSLg's
  D3D12 path must not be selected.
- Official Linux Godot 4.7.1 binary.
- Godot Mobile renderer at 1280x720.
- `yernar` profile uses logical CPUs 0-3; `torture` uses CPUs 0-1.
- Application user data and logs are isolated under
  `.superpowers/low-perf-proxy/`.

## Interface

Run from PowerShell:

```powershell
.\.superpowers\low-perf-proxy\run.ps1 -Profile yernar
.\.superpowers\low-perf-proxy\run.ps1 -Profile torture
.\.superpowers\low-perf-proxy\run.ps1 -VerifyOnly
```

`-VerifyOnly` must fail unless all fixed-environment properties can be proven.
Normal launch must first run the same verification, then start the real project.

## Limits

This proxy reproduces high frame time and memory pressure. Because lavapipe
bypasses the Windows Intel display driver and DirectX graphics scheduler, it
cannot reproduce the exact `dxgmms2.sys` kernel crash. That requires a separate
native Intel-GPU run.
