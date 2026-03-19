# Amiga Test Demo

CMake-based Amiga demo with two chipset variants:

- **demo_ecs** — ECS build: blitter-assisted C2P, 68000 chunky span renderer.
- **demo_aga** — AGA build: same C2P path plus 68020-optimized renderer (bfextu, 4× unrolled inner loop, outer loop in asm). The 68020 `.s` file is assembled with `vasmm68k_mot -m68020`; C and the rest stay 68000.

## Source layout

| File | Role |
|------|------|
| `src/main.c` | C orchestration, copper, FPS counter, `render_chunky()` |
| `src/render_chunky_span_asm.s` | ECS/68000 span renderer + `render_chunky_all_asm` |
| `src/render_chunky_span_asm_020.s` | AGA/68020 span renderer (bfextu, etc.) |
| `src/c2p_blit_4bpl_stretched_local.s` | ECS blitter C2P |
| `src/c2p_blit_4bpl_stretched_aga.s` | AGA blitter C2P (extended BLTSIZV/H) |

## Prerequisites

- **CMake** 3.20+
- **vbcc** (Amiga 68k): `vc`, `vbccm68k`, `vlink`, and for AGA **vasmm68k_mot** on `PATH`
- **VBCC** env var set to the vbcc install root (e.g. `C:\amiga-dev` or `C:\vbcc`)
- **Amiga NDK** headers: the `+aos68k` config must add the NDK include path (e.g. `-I%VBCC%/NDK_3.5/Include/include_h`) so `#include <hardware/custom.h>` resolves. If your config only has `-I%VBCC%/targets/m68k-amigaos/include`, add the NDK path to the `-cc=` / `-ccv=` lines in `config/aos68k`.

## Build

**Quick (Release, both variants):**

```bat
build.bat
```

`build.bat` sets `VBCC` if needed, configures, then builds `demo_ecs` and `demo_aga` with `--config Release`. Outputs:

- `build\Release\demo_ecs`
- `build\Release\demo_aga`

**Manual configure and build:**

Download and unzip vbcc.

http://phoenix.owl.de/vbcc/2022-03-23/vbcc_bin_win64.zip

```bat
set VBCC=C:\path\to\vbcc
cmake -S . -B build
cmake --build build --target demo_ecs --config Release
cmake --build build --target demo_aga --config Release
```

If `vc` or `vasmm68k_mot` are not on `PATH`:

```bat
cmake -S . -B build -DVC_COMPILER=C:/path/to/vc -DVASM=C:/path/to/vasmm68k_mot
```

**Debug build:**

```bat
cmake --build build --target demo_aga --config Debug
```

→ `build\Debug\demo_aga` (compiled with `-O0`).

## Output locations

| Config  | ECS binary              | AGA binary               |
|---------|--------------------------|---------------------------|
| Release | `build/Release/demo_ecs` | `build/Release/demo_aga` |
| Debug   | `build/Debug/demo_ecs`   | `build/Debug/demo_aga`   |

Single-config generators (e.g. Ninja with `CMAKE_BUILD_TYPE=Release`) also use the `Release` subdir when build type is Release.

## Run / benchmark

Run the demo; it logs to `demo.log` by default (or pass a path as first argument). On-screen and in the log you’ll see FPS and time split for R (CPU render), C2P, and S (sync). Example:

```
FPS: 3.5 | R:69% C2P:26% S:6%
```
