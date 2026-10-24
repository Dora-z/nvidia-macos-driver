# About this fork

This is a personal fork of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver), based on
**v2.5.4**. It is not an official NullMoth release and is not supported by the NullMoth project.

**The changes in this fork were written with an AI coding assistant (Claude).** The upstream project does not accept
AI-written contributions (see [CONTRIBUTING.md](CONTRIBUTING.md)), so none of this is meant to be submitted there.
Please don't report problems with this fork to the upstream project.

Tested only on one machine: GeForce GTX 1660 SUPER (Turing, 6 GB, 256 MB BAR1), macOS 15.6, a 1080p 180 Hz panel.

## Changes

Each change is its own branch on top of `v2.5.4`; `main` merges them all.

| Branch | What it does | Switch |
| --- | --- | --- |
| `hidpi-180hz` | Keeps HiDPI (scaled) desktops at the panel's native refresh rate instead of only 60 Hz | boot-arg `nvfbscalehz=<hz>` (off without it) |
| `async-surface-in` | WindowServer no longer waits for each client-surface upload; fixes a one-frame triangle flicker in uploads | `NVMTL_ASYNC_SURFIN=1` (off by default) |
| `compositor-draw-caching` | Reuses framebuffer-fetch descriptor sets and sampler-variant choices within a pass | always on |
| `angle-process-list` | `NVMTL_ANGLE_METAL` takes a list of process names (e.g. `Claude Helper`), also read from `nvrm610.conf` | `NVMTL_ANGLE_METAL` |
| `translator-sampler-arrays` | GLSL sampler arrays work through ANGLE Metal (xterm.js WebGL terminals rendered blank). Dynamic indices still read element 0 | `NVMTL_NO_AIR_TEXENV=1` disables the AIR inline step |
| `zerocopy-unmapped-vram` | Surfaces past the BAR1 budget get VRAM without a BAR1 mapping instead of a copy through system memory | on; `sysctl debug.nvrmfb_vram_unmapped=0` turns it off until reboot |
| `ws-read-marks` | Apps wait for WindowServer to finish reading a shared surface before drawing into it again (fixes header flicker on fast scroll with zero-copy) | on; `NVMTL_NO_READ_MARKS=1` or `sysctl debug.nvaccel_surface_read_on=0` |

## Licence

Same as upstream: PolyForm Noncommercial 1.0.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). No commercial use.
