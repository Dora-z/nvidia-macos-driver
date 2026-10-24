# NullMoth NVIDIA 驱动 · 个人优化版

这是 [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) 的个人 fork，基于官方 **v2.5.4**，
主要针对 Turing 显卡（GTX 16 系）上的高刷新率、窗口合成性能和 Chromium/Electron 应用的 GPU 渲染做了修复和优化。

> [!WARNING]
> - **这不是官方版本**，NullMoth 项目不提供任何支持。用这个 fork 遇到的问题请不要提交到上游仓库。
> - **本仓库的改动是在 AI 编程助手（Claude）的协助下编写的。** 上游明确不接受 AI 编写的贡献（见
>   [CONTRIBUTING.md](CONTRIBUTING.md)），所以这些改动不会、也不应该提交到上游。
> - 改动涉及内核扩展，装错可能导致开机黑屏。安装脚本会先做完整备份，并说明如何在安全模式下恢复。
> - 只在一台机器上测试过：**GeForce GTX 1660 SUPER**（Turing，6 GB 显存，256 MB BAR1）、**macOS 15.6**、1080p 180 Hz 显示器。

官方原版说明见 [README.upstream.md](README.upstream.md)。

## 改了什么

| # | 改动 | 解决的问题 | 效果 | 默认 |
| --- | --- | --- | --- | --- |
| 1 | HiDPI 高刷新率 | HiDPI（缩放）分辨率只能 60 Hz | HiDPI 也能跑到显示器原生刷新率（如 180 Hz） | 需开机参数 |
| 2 | 异步 surface 上传 | 拖动窗口卡顿（WindowServer 每帧同步等待拷贝） | 窗口拖动 36 → 45 fps，并修复一帧三角形黑/白闪烁 | 需开关 |
| 3 | 合成器绘制缓存 | Core Animation 每帧重复创建描述符集 | 降低 WindowServer 每帧开销 | 开启 |
| 4 | ANGLE 按进程启用 Metal | 只能对 Chrome 全家或全部应用开启 | 可以只给指定应用（如 Claude）开 GPU 渲染 | 需开关 |
| 5 | 着色器采样器数组 | Electron 应用里 xterm.js 终端（WebGL）一片空白 | 终端正常显示文字 | 开启 |
| 6 | 零拷贝显存（unmapped VRAM） | BAR1 只有 256 MB，开机约 20 秒就耗尽，之后所有窗口走“内存中转拷贝” | 窗口 surface 直接共享显存，不再整帧拷贝 | 开启 |
| 7 | WindowServer 读取标记 | 开零拷贝后快速滚动时标题栏闪烁 | 闪烁基本消失 | 开启 |

### 1. HiDPI 高刷新率（`hidpi-180hz` 分支，改 NVRMFB）

macOS 会为每个缩放分辨率在每个刷新率下各列一项，60 Hz 的排在最前。原版驱动只保留前 64 项，所以 HiDPI 分辨率
全部只剩 60 Hz，即使显示器原生是 180 Hz。加上开机参数 `nvfbscalehz=<刷新率>` 后，驱动会把“未缩放分辨率 → 该刷新率
下的 HiDPI 分辨率 → 其它”依次排列，最多保留 224 项。不加这个参数时行为与原版完全一致。

### 2. 异步 surface 上传（`async-surface-in` 分支，改 Metal 插件）

WindowServer 每次合成应用窗口时，都要把窗口内容（IOSurface）上传到显卡，原版会在这里同步等待拷贝完成。
在 GTX 1660 SUPER 上，拖动窗口时这个等待占了合成线程 26% 的时间，180 Hz 显示器只能跑 36 fps。
开启后上传在后台进行，合成线程不再等待，拖动提升到约 45 fps。同时把上传前的屏障从 `TOP_OF_PIPE` 改成
`ALL_COMMANDS`，修复了上传与上一帧读取重叠导致的“窗口某个三角形闪黑/白一帧”。

开关：`NVMTL_ASYNC_SURFIN=1`（默认关闭）。`NVMTL_SURFIN_STATS=1` 可每 2 秒在系统日志里输出上传统计。

### 3. 合成器绘制缓存（`compositor-draw-caching` 分支，改 Metal 插件）

Core Animation 每一遍渲染会发出几百次 framebuffer-fetch 绘制，原版每次都新建并写入描述符集。现在同一遍内视图和
掩码不变时直接复用；采样器变体的选择也按“当前管线 + 采样器参数”缓存；在同一遍内重复设置同一个管线直接跳过。

### 4. ANGLE 按进程启用 Metal（`angle-process-list` 分支，改 Metal 插件）

原版的 `NVMTL_ANGLE_METAL` 只能是 `1`（所有 Chromium 应用）或不设（仅 Chrome 家族）。现在可以写逗号分隔的进程名
列表，例如 `Claude Helper`、`Microsoft Edge Helper`，只给这些应用开启 Metal（GPU 渲染）。
另外修复了这个设置写在 `nvrm610.conf` 里时不生效的问题（读取时机早于配置加载）。

### 5. 着色器采样器数组（`translator-sampler-arrays` 分支，改着色器翻译器和 Metal 插件）

Electron 应用（如 Claude、VS Code）里的终端用 xterm.js 的 WebGL 渲染器，它的字形着色器使用 `sampler2D u_texture[16]`。
原版翻译器不支持采样器数组，管线创建失败，终端一片空白。修复包括：

- 翻译器把 `array<sampler, N>` 降级为描述符数组，并上报正确的数量；
- NVK 会把数组元素限制在其绑定点自身的描述符上，所以常量下标的第 k 个元素会指向独立的绑定点 b+k；
- 插件的绑定掩码按数组长度标记所有槽位；
- ANGLE 会把采样器数组元素指针放进 `ANGLE_TextureEnvs` 结构再传给未内联的函数，翻译前先在 AIR 上做内联
  （`NVMTL_NO_AIR_TEXENV=1` 可关闭这一步）。

已知限制：**运行时动态下标**仍然只读到第 0 个元素（GLSL ES 只允许常量下标，所以 ANGLE 生成的着色器不受影响）。

### 6. 零拷贝显存（`zerocopy-unmapped-vram` 分支，改 NVRMFB 和 NVAccel）

驱动原本给每个窗口 surface 都做 BAR1 映射，而 Turing 卡的 BAR1 硬件上限只有 256 MB（扣掉显示占用约 208 MB），
开机约 20 秒后就耗尽。之后新的 surface 都会被拒绝分配显存（几分钟内上万次），退回到“每个进程一份私有副本 + 每帧经
系统内存拷贝”。

实际上 GPU 访问这些显存根本不需要 BAR1 映射（共享、翻页、换出都通过 RM 句柄）。现在当 BAR1 预算用完，或预算内
映射失败时，驱动直接分配不带 BAR1 映射的显存（上限默认 2048 MB）。实测开机一段时间后有 4000+ 个 surface、
约 1.2 GB 走这条路径，拒绝次数为 0，且计数器显示系统从未尝试以 CPU 方式访问这些显存。

开关：默认开启。`sudo sysctl debug.nvrmfb_vram_unmapped=0` 可关闭（对之后新分配的 surface 生效，重启后恢复开启）；
`debug.nvrmfb_vram_unmapped_cap_mb` 调整上限。

### 7. WindowServer 读取标记（`ws-read-marks` 分支，改 NVAccel 和 Metal 插件）

开启零拷贝后，WindowServer 直接从应用的显存读取窗口内容来合成。应用（如 Chromium）在 Core Animation 归还缓冲后
会立刻往里画下一帧，但此时 WindowServer 的 GPU 可能还没读完，于是屏幕上出现“画了一半”的帧：粘性标题栏下面
滚动的内容会透出来，表现为快速滚动时标题栏闪烁。

现在 WindowServer 提交合成命令时，会把它要读取的共享 surface 在内核里标记为“正在读”，GPU 完成后清除；其它进程
提交写入共享 surface 的命令前，会在内核里等待这个标记清除（最多 50 ms）。实测约 11% 的写入确实撞上了正在进行的
读取并等待，闪烁基本消失。

开关：默认开启。`NVMTL_NO_READ_MARKS=1` 或 `sudo sysctl debug.nvaccel_surface_read_on=0` 可关闭。

## 怎么使用

### 前提

- 已经用 [1401](https://github.com/nullmoth/1401) 装好官方 **NullMoth 2.5.3 或 2.5.4**，并且能正常进入桌面；
- macOS 15 Sequoia，Intel / x86_64（macOS 26 未构建、未测试，安装脚本会拒绝）。

### 1. 安装

#### 方式一：下载预编译版本（推荐）

1. 在 [Releases](https://github.com/Dora-z/nvidia-macos-driver/releases) 下载最新的 `nullmoth-fork-*.zip`，双击解压。
2. 打开“终端”，进入解压出来的文件夹（可以输入 `cd ` 后把文件夹拖进终端窗口），运行：

```bash
sudo bash install.sh
```

文件夹里的 `SHA256SUMS.txt` 是各文件的校验值，可以用 `shasum -a 256 -c SHA256SUMS.txt` 核对。

#### 方式二：自己编译

需要 Xcode 命令行工具（`xcode-select --install`）、Rust（[rustup](https://rustup.rs)）和两个源码依赖：

```bash
git clone --depth 1 --branch 615.78.08 https://github.com/NVIDIA/open-gpu-kernel-modules.git ~/ogkm
```

```bash
git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git ~/vulkan-headers
```

然后：

```bash
git clone https://github.com/Dora-z/nvidia-macos-driver.git && cd nvidia-macos-driver
```

```bash
OGKM=~/ogkm VKH=~/vulkan-headers bash fork/build.sh
```

```bash
sudo bash fork/install.sh
```

编译产物在 `fork/out/`：`NVAccel.kext`、`NVRMFB.kext`、`NVMTLDriver`（Metal 插件）、`libnvmtl_translate.dylib`（着色器翻译器）。

#### 安装脚本做了什么

1. 先用新的 NVAccel / NVRMFB 试建一次内核扩展集合（失败则什么都不改）；
2. 把要替换的文件（两个 kext、内核扩展集合、插件、翻译器、`nvrm610.conf`）备份到 `~/nullmoth-fork-backup-日期/`；
3. 安装并发布新的内核扩展集合。

完成后**重启**（注销不会重启 WindowServer）。驱动的其它部分（NVRM、NVRMAGDC、NVK 等）保持官方原样。

### 2. 打开可选功能

**HiDPI 高刷新率**：在开机参数里加 `nvfbscalehz=<你的刷新率>`（例如 `nvfbscalehz=180`），同时保留官方的
`nvfbhidpi=1`。OpenCore 用户在 `config.plist` 的 `NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args`
里添加，然后重启，在“系统设置 → 显示器”里选 HiDPI 分辨率和刷新率。

**插件开关**用 `conf.sh`（仓库里是 `fork/conf.sh`，下载包里在文件夹根目录）写入 `/Library/GPUBundles/nvmtl/nvrm610.conf`：

```bash
sudo bash fork/conf.sh NVMTL_ASYNC_SURFIN 1
```

```bash
sudo bash fork/conf.sh NVMTL_ANGLE_METAL "Claude Helper"
```

不带参数运行 `bash fork/conf.sh` 查看当前设置，`sudo bash fork/conf.sh <KEY> off` 删除。改完重启生效
（只影响普通应用的话，退出并重新打开那个应用即可）。

| 开关 | 作用 |
| --- | --- |
| `NVMTL_ASYNC_SURFIN=1` | 开启异步 surface 上传（推荐） |
| `NVMTL_SURFIN_STATS=1` | 每 2 秒在系统日志里输出上传统计 |
| `NVMTL_ANGLE_METAL=<进程名,...>` | 给指定的 Chromium/Electron GPU 进程开启 Metal；`1` 表示全部 |
| `NVMTL_NO_READ_MARKS=1` | 关闭读取标记（排查问题用） |
| `NVMTL_NO_AIR_TEXENV=1` | 关闭 ANGLE 着色器内联步骤（排查问题用） |

进程名要写 GPU 进程的可执行文件名，例如 Claude 是 `Claude Helper`，有的应用是 `xxx Helper (GPU)`。打开那个应用后，
用下面的命令列出正在运行的 GPU 进程（每行路径的最后一段就是进程名）：

```bash
ps -axww -o args= | grep -- '--type=gpu-process' | grep -v grep | sed -E 's/ --type=gpu-process.*//'
```

### 3. 确认生效

```bash
sysctl debug.nvrmfb_vram_unmapped debug.nvrmfb_vram_unmapped_grants debug.nvrmfb_vram_unmapped_refused
```

```bash
sysctl debug.nvaccel_surface_read_asks debug.nvaccel_surface_read_waits debug.nvaccel_surface_read_timeouts
```

- `nvrmfb_vram_unmapped_grants` 在开机后持续增长、`_refused` 为 0：零拷贝在工作；
- `nvaccel_surface_read_asks` 在使用 GPU 渲染的应用里增长：读取标记在工作，`_waits` 是实际等待的次数，
  `_timeouts` 应该很少。

### 4. 恢复原版

```bash
sudo bash ~/nullmoth-fork-backup-<日期>/restore.sh
```

然后重启。如果装完无法进入桌面：开机进入**安全模式**（安全模式不加载第三方内核扩展），在终端里运行上面的命令再重启。

### 注意

- **用 1401 升级或重装官方驱动会覆盖本 fork 的所有改动。** 官方出新版本后，需要等本 fork 合并新版本，再重新构建安装。
- 安装脚本只替换 4 个文件，其它组件的版本号仍显示为官方版本号，这是正常的。

## 分支

每项改动是基于 `v2.5.4` 的独立分支，`main` 合并了全部分支，另加 `fork/` 下的脚本和本说明。

| 分支 | 内容 |
| --- | --- |
| `hidpi-180hz` | 1. HiDPI 高刷新率 |
| `async-surface-in` | 2. 异步 surface 上传 |
| `compositor-draw-caching` | 3. 合成器绘制缓存 |
| `angle-process-list` | 4. ANGLE 按进程启用 Metal |
| `translator-sampler-arrays` | 5. 着色器采样器数组 |
| `zerocopy-unmapped-vram` | 6. 零拷贝显存 |
| `ws-read-marks` | 7. WindowServer 读取标记 |

## 许可证

与上游相同：PolyForm Noncommercial 1.0.0（见 [LICENSE](LICENSE)、[NOTICE](NOTICE)），**禁止商业用途**。
NVIDIA 固件、open-gpu-kernel-modules 和 Mesa 的许可证见 `licenses/`。
