# Amiga Test Demo

This project now builds with CMake and produces two variants:

- `demo_ecs`: ECS-oriented build using the blitter-assisted C2P path.
- `demo_aga`: AGA-oriented build using the blitter-assisted C2P path and a 68020-tuned chunky span renderer.

## Source Layout

All source files live under `src/`:

- `src/main.c`
- `src/render_chunky_span_asm.s` (ECS/default renderer)
- `src/render_chunky_span_asm_020.s` (AGA/68020-optimized renderer)
- `src/c2p_blit_4bpl_stretched_local.s`
- `src/c2p_blit_4bpl_stretched_aga.s`

## Prerequisites

- CMake 3.20+
- vbcc toolchain with `vc` available on `PATH` (or pass a full path via `VC_COMPILER`)

## Build

Configure once:

```bat
cmake -S . -B build
```

If `vc` is not on `PATH`, configure with:

```bat
cmake -S . -B build -DVC_COMPILER=C:/path/to/vbcc/bin/vc
```

Build both variants:

```bat
cmake --build build
```

Build only ECS:

```bat
cmake --build build --target demo_ecs
```

Build only AGA:

```bat
cmake --build build --target demo_aga
```

## Output Binaries

Built binaries are placed in the `build` directory:

- `build/demo_ecs`
- `build/demo_aga`
