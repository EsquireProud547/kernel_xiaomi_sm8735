# Onyx 内核构建流水线 —— 最终实现总结

本文记录 `kernel_xiaomi_sm8735` 分支上 `.github/workflows/build-onyx.yml`
的**最终实现状态**：每一项功能究竟落在哪个文件、用什么机制实现、验证到什么程度。

面向的读者是以后要改这套流水线的人。构建细节见
[`README-build-onyx.md`](README-build-onyx.md)，AnyKernel3 打包细节见
[`anykernel/AK3-NOTES.md`](anykernel/AK3-NOTES.md)。

- **目标设备**：Xiaomi SM8735（代号 onyx），Oryon 平台，**仅 aarch64**
- **内核源码**：`android15-6.6` @ `6.6.82`
- **上游来源**：`gki-clo` 仓库的 `build-capybara.yml`（同设备、不同内核树）
- **远端**：`https://github.com/EsquireProud547/kernel_xiaomi_sm8735.git`，分支 `oss`
- **当前 HEAD**：`8702d7358702`

---

## 1. 成果一览

| 功能 | 状态 | 实现位置 |
|------|------|----------|
| 官方 Kleaf 配置合成 | ✅ | `build-onyx.yml:251` Configure 步骤 |
| 三道配置闸门 | ✅ 3/3 通过 | 同上，`:364` / `:433` / `:471` |
| BTF（eBPF/CO-RE） | ✅ CI 验证 | GKI base 提供 + `:322` 守卫 |
| 模块签名 SHA-512 | ✅ CI 验证 | GKI base 提供 |
| Droidspaces SYSVIPC | ✅ kABI 安全 | `droidspaces_sysvipc.patch` |
| ReSukiSU (KernelSU) | ✅ CI 验证 | `build-onyx.yml:203` |
| SUSFS | ✅ CI 验证 | `susfs4ksu` + `onyx_susfs.fragment` |
| HZ 300 / ThinLTO / zram lz4 | ✅ CI 验证 | `onyx_gki.fragment` |
| AutoFDO | ⚠️ 非致命 | `build-onyx.yml:340` |
| 调试裁剪（ABI 安全） | ✅ 15 项 | `onyx_debug_reduction.fragment` |
| Xiaomi vendor 内建 | ⚠️ 过滤偏粗 | `onyx_perf.config` 的 `=y` |
| ccache 三级键 | ✅ 7.15% 命中 | `build-onyx.yml:193` |
| AnyKernel3 刷机包 | ⚠️ 待实机验证 | `anykernel/` |
| BBRv3 / NTSYNC / Baseband-guard | ❌ 未移植 | 6.6.82 无此特性 |
| `Module.symvers` CRC 校验 | ❌ 未实现 | 需设备基线 |

图例：✅ CI 日志实证 · ⚠️ 代码就绪但有已知局限 · ❌ 未做

---

## 2. 流水线总图

`ubuntu-26.04`，`timeout-minutes: 120`，**17 个 step**，
`permissions: contents: read`。

```
 1  Checkout kernel source          ref: oss, fetch-depth: 0
 2  Fast cleanup + swap            删 dotnet/swift/go，固定重建 20GB swap
 3  Install build dependencies     flex bison libelf-dev lz4 …
 4  Install pahole for BTF  ★if    dwarves；< 1.21 则降级而非失败
 5  Patch libbpf            ★if    C23 strchr const 修正
 6  Cache Clang toolchain          actions/cache
 7  Download Clang toolchain  ★    android17-release/clang-r596125
 8  Setup Clang
 9  Setup ccache                   三级 restore-keys
10  Apply ReSukiSU                 curl setup.sh | bash -s main
11  Apply SUSFS patches      ★if   susfs4ksu @ gki-android15-6.6
12  Apply Droidspaces kABI patch   唯一不允许静默失败的补丁
13  Configure kernel               ★ 合成 + 3 闸门（见 §3）
14  Build kernel                   make -j$(nproc) … KCFLAGS="-w"
15  Package AnyKernel3             见 §7
16  Upload kernel package          upload-artifact，archive: false
17  Build summary                  写入 STEP_SUMMARY 表格
```

★ = 受 `workflow_dispatch` 输入控制。

`permissions: contents: read` 是刻意收紧的。流水线把
`curl … | bash -s`（第 10 步）直接喂给 shell，并 clone 一个会移动的分支
（`susfs4ksu`），被投毒的依赖不应该能往仓库里推东西。

---

## 3. 配置合成：照抄官方 Kleaf 做法

### 3.1 合成链

这是本次移植**最核心的改动**。放弃手工烘焙的 `onyx_defconfig`，
改为复刻 stock Kleaf mixed-build（`build.config.msm.perf` +
`build.config.msm.common`）的合成方式：

```
  gki_defconfig                     stock GKI 6.6.82 基线（786 行）
    + onyx_gki.fragment             Capybara 调优（仅增量）
    + vendor_builtin.fragment       vendor/onyx_perf.config 的 =y 行
    + onyx_susfs.fragment           仅当 enable_susfs=true
    + onyx_autofdo.fragment         仅当 AutoFDO 档案下载成功
  ── merge_config.sh -m -r -y ──▶  out/arch/arm64/configs/onyx_gki_defconfig
  ── make onyx_gki_defconfig ────▶  out/.config
```

`vendor_builtin.fragment` 和 `onyx_autofdo.fragment` 都是**运行时生成**的，
不落盘入库。生成逻辑见 §6、§5.3。

### 3.2 三道闸门

闸门不是自己发明的，是从 `build.config.msm.common` 抄的。它们的作用是：
**一个没生效的 fragment 必须让构建失败，而不是让功能静默消失。**

| # | 位置 | 检查 | 失败信息 |
|---|------|------|----------|
| 1 | `:97` | `merge_config.sh` 不得报告任何 `Previous value: …=[ym]` | `Detected overridden config!` |
| 2 | `:105` | `make <defconfig>` 无 `warning:`，且 `out/.config` 非空 | `Treating config warnings as errors` |
| 3 | `:125` | `scripts/diffconfig` 不得有 `-SYM y` / `-SYM m` / `-SYM y -> m` | `Defconfig fragment did not apply as expected` |

**fragment 只增不减**。想翻转基线已有的值，不是写 fragment，而是在合并后
用 `scripts/config` 改（§3.4）。这样闸门 1 才能保持严格。

### 3.3 闸门 3 的一处刻意放宽

官方闸门 3 见到**任何** `-` 开头的行就失败。我们的实现只过滤掉
`^-[A-Za-z0-9_]+ n$` 这一种：

```bash
DRIFT=$(grep -E '^-' "$MERGE_OUT" | grep -vE '^-[A-Za-z0-9_]+ n$' || true)
```

原因：调试裁剪关掉 `CONFIG_UBSAN` 后，它的子选项在 `.config` 里不再显示，
`diffconfig` 会把一个**本来就没设过**的符号报成 `-UBSAN_BOOL n`。这不是
"请求了但被丢弃"，是"不再可见"。

必须失败的仍然是**请求开启却没活下来**的符号——`y`、`m`、`y -> m` 三种形态
一个都不放过。

> 注意：`diffconfig` 在读不到文件时**退出码仍是 0**。所以保护"配置缺失"的不是
> 闸门 3，是闸门 2 里的 `[ ! -s out/.config ]` 断言。闸门 3 的检查只是防止
> 工具本身出错时被误判成"无漂移"。

### 3.4 合并后的刻意覆盖

只有 4 类，共 18 个符号。所有覆盖都在 `make` **之前**完成，所以闸门 3 仍然是
一句真话。

| 覆盖 | 符号数 | 原因 |
|------|--------|------|
| 调试裁剪 | 15 | `onyx_debug_reduction.fragment`，全是 ABI 安全项（见 §5.4） |
| 关 BTF | 3 | 只在 `enable_btf=false` 或 pahole 过旧时；基线是 `=y`，写 fragment 会撞闸门 1 |
| `UAPI_HEADER_TEST` | 1 | `depends on CC_CAN_LINK`（编译探针结果），defconfig 满足不了 |
| — | — | 以上之外，`make` 之后不再动配置 |

关 BTF 时必须**连带**关掉 `DEBUG_INFO_BTF_MODULES` 和
`MODULE_ALLOW_BTF_MISMATCH`，否则闸门 3 会把后者报成"请求了却被丢弃"。

### 3.5 用 stock GKI base 顺带修好的三件事

早期手写的 `onyx_defconfig`（已删除）有三个问题，切回 `gki_defconfig`
后全部消失，因为它们都不是调优项，而是基线本身该有的：

1. **BTF 静默关闭** —— `CONFIG_DEBUG_INFO_REDUCED=y` 会硬性阻断
   `DEBUG_INFO_BTF`（`lib/Kconfig.debug:375`），而 `olddefconfig` 丢弃它时
   **一声不吭**。
2. **模块签名是 SHA-1** —— 且没有 `MODULE_SIG_PROTECT`。
3. **调试裁剪误伤 `CONFIG_PROFILING`** —— 级联干掉 27 个符号（见 §5.4）。

---

## 4. BTF 完整支持

BTF 是这次移植里"差点悄悄坏掉"最典型的一项，逐条说明。

### 4.1 三个前提

| 前提 | 满足方式 |
|------|----------|
| `DEBUG_INFO_BTF` 不被 `DEBUG_INFO_REDUCED` 阻断 | 裁剪清单里**明令禁止**加这两项，文件顶部有注释警告 |
| pahole ≥ 1.21 | `:138` 装 `dwarves`；版本 < 1.21 时**降级为无 BTF**并记 `BTF_UNAVAILABLE=1`，不硬失败 |
| libbpf 能用现代宿主编译器编过 | `.github/actions/libbpf_strchr_const.patch` |

第二条来自 `lib/Kconfig.debug`：
`DEBUG_INFO_BTF depends on !DEBUG_INFO_DWARF5 || PAHOLE_VERSION >= 121`。
实测 pahole 版本是 **131**，远超要求，同时具备 `PAHOLE_HAS_BTF_TAG`（≥ 1.23），
bpftool 的 fentry/fexit CO-RE 定位可用。

第二条那个 patch 值得单说：`CONFIG_DEBUG_INFO_BTF` 会拉起
`tools/bpf/resolve_btfids`，它链接 `tools/lib/bpf`，而
`tools/lib/bpf/Makefile:89` 写死了 `override CFLAGS += -Werror`。C23 起
`strchr` 是 const-correct 的，于是 `libbpf.c:11241` 直接编译失败且不可绕过。
一行强转即可：

```c
next_path = (char *)strchr(s, ':');
```

patch 是**幂等**的（`grep` 先检查），重复应用不会失败。

### 4.2 产物里确实有 BTF

`scripts/link-vmlinux.sh` 把 `.BTF` 标为 `alloc,readonly`，所以
`objcopy -O binary` 之后它仍然留在 `Image` 里。CI 验证过。

### 4.3 `MODULE_ALLOW_BTF_MISMATCH` 是必需项

我们编出来的 BTF 和手机 `vendor_dlkm` 里那些**原厂预编译模块**的 BTF
必然不一致。`kernel/bpf/btf.c:7373-7390` 处的检查会直接拒绝加载。
`CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` 就是为此存在的。

这也解释了为什么关 BTF 时必须把它一起关（§3.4）——它 `depends on`
`DEBUG_INFO_BTF_MODULES`，留着会成为闸门 3 的漂移项。

### 4.4 闸门后的显式断言

```bash
grep -q "^CONFIG_DEBUG_INFO_BTF=y" out/.config \
  || { echo "::error::CONFIG_DEBUG_INFO_BTF was dropped"; exit 1; }
```

因为 `olddefconfig` 丢弃 BTF 时是**完全静默**的（§4.1 第一条），
必须显式检查。

---

## 5. 各功能的实现细节

### 5.1 Droidspaces（POSIX IPC）

`CONFIG_SYSVIPC=y` 会把 `struct sysv_sem` / `sysv_shm` 插到
`task_struct` **中间**，把后面所有字段往后推。vendor 模块是按冻结的 GKI
ABI 编的，会读错偏移，然后开机循环。

解法是 `.github/actions/droidspaces_sysvipc.patch`（为 6.6.82 重新生成，
**零 offset、零 fuzz**）：把这两个字段挪到已有的
`ANDROID_KABI_RESERVE(6/7/8)` 填充槽上。

- `CONFIG_ANDROID_KABI_RESERVE=y`（`drivers/android/Kconfig` 默认）让那三个
  槽成为真实的 `u64 android_kabi_reserved6/7/8` 成员 → `task_struct` 总大小
  和所有后续偏移不变。
- `_ANDROID_KABI_REPLACE()` 发出 `sizeof(sysv_sem) <= 8` 的
  `_Static_assert` → 溢出是**编译错误**，不是运行期 bootloop。
- `ANDROID_KABI_USE()` **不受** `CONFIG_ANDROID_KABI` 门控（只有 RESERVE 侧受控），
  所以这在本身不强制 kABI 的 GKI 树上照样生效。
- `__GENKSYMS__` 路径保留原始 reserve 字段，genksyms 看到的 ABI 仍然稳定。

这是流水线里**唯一不允许静默失败**的补丁（`:248` 无 `|| true`），
合并后再断言 `CONFIG_SYSVIPC=y`（`:511`）。

配套启用的还有 `POSIX_MQUEUE`、`IPC_NS`、`PID_NS`、`DEVTMPFS`、
`USER_NS`、`TMPFS_POSIX_ACL`、`NETFILTER_XT_MATCH_ADDRTYPE`。

### 5.2 ReSukiSU + SUSFS

**ReSukiSU**（`:203`）：`curl … setup.sh | bash -s -- <branch>`。
失败不终止构建，记 `KSU_STATUS=FAILED` 并发 `::warning::`。

**SUSFS**（`:215`）：clone `susfs4ksu` 的 `gki-android15-6.6` 分支
（对应本树），打
`50_add_susfs_in_gki-android15-6.6.patch`，然后**额外拷贝** susfs4ksu
自带的 `include/linux/*` 和 `fs/*`——patch 本身只加胶水，上游源码是完整版。

`onyx_susfs.fragment` 里**只写两个符号**：

```
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
```

`CONFIG_KSU_SUSFS` 的全部子选项都是 `bool … default y`，开了父项就全开：

```
KSU_SUSFS_SUS_PATH          KSU_SUSFS_SPOOF_UNAME
KSU_SUSFS_SUS_MOUNT         KSU_SUSFS_ENABLE_LOG
KSU_SUSFS_SUS_KSTAT         KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
KSU_SUSFS_OPEN_REDIRECT     KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
KSU_SUSFS_SUS_MAP
```

> 该列表来自 `susfs4ksu` 的 Kconfig，但那个仓库是 CI 运行时才 clone 的
> （`kernel_patches/` 里不含 Kconfig 全文），所以这里不写死子项**个数**——
> 跟着 susfs4ksu 改动漂移一个数字，比漏一个符号更糟。父项 `=y` 才是唯一
> 需要维护的东西。

`gki-clo` 当年是盲目循环追加 8 个符号，其中 3 个在这个分支上**根本不存在**
（`KSU_SUSFS_HAS_MAGIC_MOUNT`、`KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_KSU_DENYLIST`、
`KSU_SUSFS_SUS_OVERLAYFS`），被闸门 3 当场抓住。只写语义确定的那两个，
对 susfs4ksu 下次改名免疫。

`.github/actions/fixup_susfs.sh` 从 gki-clo 逐字节复制：SUSFS 的 context hook
需要 `fs/proc/base.c` 里有 `<linux/dma-buf.h>`，CLO 树没有，脚本负责插。

### 5.3 AutoFDO

在**合并之前**探测档案能否下载
（`android.googlesource.com/kernel/common … /aarch64/afdo.tar.gz`）。
成功就生成 `onyx_autofdo.fragment`（`CONFIG_AUTOFDO_CLANG=y`）并把它
**加进 fragment 列表**，同时设 `CLANG_AUTOFDO_PROFILE`（`scripts/Makefile.autofdo`
精确匹配这个变量名）。

做成 fragment 而不是合并后 `scripts/config` 改，是为了不破坏闸门 3 的严格性。
失败是**非致命**的：那个 `+archive` 端点在分支没建过档案时会 5xx。

### 5.4 调试裁剪

`onyx_debug_reduction.fragment`，15 项，全部是"关掉不改变任何导出结构体大小
或顺序"的选项——这正是它能安全作用于按冻结 GKI 符号表编译的 vendor 模块
的原因。

| 类别 | 符号 |
|------|------|
| Slab / 启动调试 | `DEBUG_MISC` `DEBUG_MEMORY_INIT` `CMA_DEBUGFS` `CLEANCACHE` |
| printk 冗长 | `PRINTK_CALLER` `PRINTK_TIME` |
| RCU 停顿跟踪 | `RCU_TRACE` |
| 蓝牙 debugfs | `BT_DEBUGFS` |
| UBSan（父项 + 5 个子项） | `UBSAN` `UBSAN_BOUNDS` `UBSAN_ARRAY_BOUNDS` `UBSAN_LOCAL_BOUNDS` `UBSAN_SANITIZE_ALL` `UBSAN_TRAP` |

**清单里绝对不能加 `CONFIG_PROFILING`。** gki-clo 的清单里有，实测会级联干掉
27 个符号：

```
PROFILING → PERF_EVENTS → BPF_EVENTS → BPF_LSM
              │              │
              │              └→ UPROBE_EVENTS → UPROBES
              └→ HW_PERF_EVENTS → ARM_PMU / ARM_PMUV3
                                 → HAVE_HW_BREAKPOINT
```

即：所有硬件性能计数器、全部 uprobe 支持、BPF LSM 全部消失，而内核**照样编译
成功**。这直接抵消了发 BTF 给 eBPF 的意义。实测数据：加
`-d CONFIG_PROFILING` 掉 27 个符号，不加则正好掉上面这 15 个、一个不多。

### 5.5 性能调优（`onyx_gki.fragment`）

| 项 | 值 | 理由 |
|---|---|---|
| `CONFIG_HZ_300` | 300 | GKI 默认 250；`HZ_400/500` 属于非 GKI 档位 |
| `CONFIG_LTO_CLANG_THIN` | ThinLTO | **不能**用 FullLTO：`CONFIG_CFI_CLANG=y`（KCFI）的 type-id 重编号与 FullLTO 冲突（gki-clo `98763e396491`）。GKI base 是 `LTO_NONE` |
| `CONFIG_ZRAM_DEF_COMP_LZ4` | lz4 | GKI 默认 lzo-rle。zram 热路径上解压速度比压缩率重要。`CONFIG_CRYPTO_LZ4` base 已是 `=y`，依赖成立 |

### 5.6 Xiaomi vendor 片段

`vendor/onyx_perf.config` 有 33 个 `=m` 条目，是 OEM 模块，链接
`msm-kernel` vendor 镜像导出的符号——**单树 GKI 构建里那个镜像根本不存在**。
全量合并会让 modpost 炸掉：

```
ERROR: modpost: "qcom_smem_alloc" [...mca_qcom_smem.ko] undefined!
ERROR: modpost: "pwrkey_irq_notifier_list" [...mtdoops.ko] undefined!
```

厂商是在 vendor 内核里对着 KMI 符号表编这些模块的，单树 GKI 编不了。
而且它们**从来不会被打包**——设备从 `vendor_dlkm` 加载原厂的。

所以只取 `=y`：

```bash
grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$VENDOR_FRAGMENT" > vendor_builtin.fragment
```

过滤器是从片段本身派生的，小米以后加条目它自动跟着对。

**已知局限（过滤偏粗）**：4 个 `=y` 条目里，`JOYSTICK_XPAD_FF` 和
`JOYSTICK_XPAD_LEDS` 是**真的**（`JOYSTICK_XPAD` 是 in-tree 驱动，内建），
但 `INPUT_FINGERPRINT` 和 `FOD_FINGERPRINT` 是**空壳**——真正用它们的驱动
是 `CONFIG_FINGERPRINT_MI_FP=m`，被过滤器丢了。

那个驱动**本身能链接**（本地验证，exit 0），所以完全可以加白名单。但加之前
必须逐个验证能链接，因为链接不过的那个会让整个构建在 modpost 阶段失败。

### 5.7 工具链与 ccache

- **Clang**：`clang-r596125`，分支 `android17-release`，从
  `android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive`
  取 tarball，`actions/cache` 按版本 + OS 缓存。
- **ccache**：三级 `restore-keys`（精确 → 同分支 → 仅版本），上限 3G。
  `CCACHE_NOHASHDIR=true` + `CCACHE_HARDLINK=true` +
  `CCACHE_COMPILERCHECK` 固定为 `%compiler% -dumpmachine; %compiler% -dumpversion`。
- **swap**：runner 镜像可能自带活跃 swap，裸 `if` 检查会漏掉，所以每次
  `swapoff` → `rm` → `dd` → `mkswap` → `swapon` 重建 20GB（gki-clo `18e63ee0098f`）。

---

## 6. 构建与产物

### 6.1 make 的退出码

```bash
set +e
make -j"$JOBS" O=out CC="ccache clang" LLVM=1 LLVM_IAS=1 KCFLAGS="-w" 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -e
```

`PIPESTATUS[0]` 不是可选项。`make | tee | tail` 的退出码来自 `tail`，恒为 0。
更糟的是 arm64 是在 modpost **之后**才出 `Image`，一次热缓存重跑如果 `out/`
里留着旧的 `Image`，就会一路骗过检查并宣称 `Build SUCCESSFUL`。

Configure 步骤（`:443`）同样用 `PIPESTATUS[0]`，修复前 defconfig 失败会混过
`set -e` 留下缺失的 `out/.config`，下游只能靠 diffconfig 打印的用法示例里那行
以 `-` 开头的文本"碰巧"被闸门 3 匹配到——构建因为一个毫不相干的原因失败，
还打印一条让人摸不着头脑的报错。

### 6.2 实测数据（一次全绿运行）

| 指标 | 值 |
|------|-----|
| 总耗时 | 22.6 min |
| 其中 build | 947 s |
| checkout | 190 s |
| ccache 命中率 | 7.15%（缓存来自一次在配置阶段就失败的运行） |
| 产物 | `Onyx-Kernel-v5-20261004.zip`，19M |
| 模块数 | 96 |
| `CONFIG_HZ` | 300 |
| LTO | ThinLTO |
| zram | lz4 |
| `PAHOLE_VERSION` | 131 |
| `MODULE_SIG_HASH` | `sha512` |
| `MODULE_SIG_PROTECT` | y |
| 闸门 | 3/3 通过 |

---

## 7. AnyKernel3 打包

### 7.1 文件构成

- **脚本**来自上游 `osm0sis/AnyKernel3` @ `020dfec`（2026-09-04），
  包括 `ak3-core.sh` 和 `META-INF/`。
- **7 个二进制**（`busybox` `magiskboot` `magiskpolicy` `fec`
  `httools_static` `lptools_static` `snapshotupdater_static`）**保持 aarch64**。

### 7.2 ⚠️ 上游 master 只装 32 位 ARM —— 这个坑踩过一次

**上游 master 提供的 `tools/` 里全部是 ARM 32 位。** 当时整目录替换，
把本仓库的 aarch64 二进制全换成了 32 位，结果 BakaSU 自带的 AK3 刷入工具
刷不进去。

真因：SM8735 是 Oryon 平台，**不执行 AArch32**，32 位二进制直接
`exec format error`。BakaSU 注入的

```sh
cp -f '<BIN>/mkbootfs' "$AKHOME/tools/mkbootfs" || exit 1;
```

因此中止。

这个 bug 一开始排查错了方向，先后排除了三个假设：

| 假设 | 排除依据 |
|------|----------|
| BakaSU 需要 `PATCH_MARKER = "chmod -R 755 tools bin;"` 恰好出现一次 | 计数恰好为 1，合规 |
| zip 条目带 `./` 前缀导致类型识别失败 | 无前缀，`ZipType.detect` → `KERNEL`，正确 |
| `BLOCK=boot` 裸名无法解析 | 被 `ak3-core.sh:1019` 的顶层 `setup_ak;` 提前解析 |

补充一条容易再次踩的：上游 `setup_bb()` 的架构探测**只检查 `tools/x86` 和
`tools/arm`，没有 `tools/arm64` 分支**，所以 aarch64 二进制必须直接放在
`tools/` 下，不能建子目录。

`anykernel/AK3-NOTES.md` 把这个清单写死了。要刷新 aarch64 二进制，
从 Magisk release 或 AIK-mobile 取，**不要**从 AK3 上游取。

### 7.3 设备适配

`anykernel/anykernel.sh` 里几个关键决定：

- **变量全大写**。`ak3-core.sh` @ `020dfec` 只读大写名（`BLOCK`、
  `IS_SLOT_DEVICE`、`RAMDISK_COMPRESSION`、`PATCH_VBMETA_FLAG`、
  `NO_MAGISK_CHECK`）。上游 `cea8f97` "remove all backwards compat"
  删掉了小写兼容写法，更新前的小写形式会被**静默忽略**。
- `do.devicecheck=0`（关掉机型校验）、`NO_MAGISK_CHECK=1`。
- `IS_SLOT_DEVICE=auto`。
- **init_boot 自动分流**：带 `init_boot_a` 符号链接的设备（ramdisk 在
  `init_boot` 分区、kernel 在 `boot`）走 `split_boot` + `flash_boot`，
  只重打 kernel 那一半，正确且快得多；其余走普通 `dump_boot` + `write_boot`。
- **版本号在打包时注入**。`sed -i "s|^kernel.string=.*|kernel.string=${KS}|"`
  替换占位值。`META-INF/.../update-binary` 读
  `anykernel.sh` 的 `kernel.string` 属性并 `ui_print` 出来——
  这一行**就是**整个开机 banner，不存在第二条需要 sed 的 `ui_print`。

### 7.4 打包命令

```bash
zip -r9 "../$ZIP_NAME" ./* -x '*.md' '*placeholder'
```

沿用上游 README 的命令，做了一处放宽：

- `*.md` —— 上游 `README.md` 加上我们的 `AK3-NOTES.md`，都是开发者文档，
  设备端不需要。
- `*placeholder` 保留（那些文件只为在 git 里占住空目录，而目录本身必须留着，
  `ak3-core.sh` 期望解压后 `ramdisk/` 和 `patch/` 存在）。
- **`LICENSE` 刻意保留**——上游要求"必须留在最终 zip 里，以遵守二进制再
  分发许可和 AK3 脚本的许可"。

### 7.5 其他打包分支

- **DTB**：目前是**死代码**。`arch/arm64/boot/dts/qcom` 里有 160 个 dtsi，
  `*onyx*` / `*sm8735*` 匹配数为 **0**——本树没有目标 SoC 的设备树，设备由
  vendor 侧提供。保留是因为一旦换用带 DTS 的树它立刻生效，而删掉它会让那天
  静默丢失 `dtb/`。
- **`modules/`**：`bundle_modules` 输入为 true 时把 `.ko` 放进 zip，
  **仅供 adb 手工测试**。AnyKernel3 不会刷它们（那需要重打 `vendor_dlkm`）。

---

## 8. 闸门抓到的 bug（失败史）

这一节是本文档最有价值的部分。**每一个 bug 都是闸门或显式断言抓到的**，
不是靠人肉看日志。

| # | 症状 | 真因 | 抓它的机制 |
|---|------|------|-----------|
| 1 | `modpost: "qcom_smem_alloc" undefined!`、`"pwrkey_irq_notifier_list" undefined!` | 33 个 OEM `=m` 模块被全量合并，单树 GKI 没有 vendor 镜像提供符号 | modpost 报错；修复为只取 `=y` |
| 2 | `warning: symbol value '"/system/susfs"' invalid for KSU_SUSFS_SUS_PATH` | 该符号是 **bool** 不是 string | 闸门 2 |
| 3 | `-KSU_SUSFS_HAS_MAGIC_MOUNT y` 等 3 行 + `-UAPI_HEADER_TEST y` | 3 个符号在 `gki-android15-6.6` 上不存在；`UAPI_HEADER_TEST` 依赖编译探针 | 闸门 3 |
| 4 | defconfig 失败却继续往下跑，`.config` 缺失 | `make \| tee \| tail` 退出码来自 `tail` | 闸门 2 缺 `PIPESTATUS[0]`，后补 `-s out/.config` 断言 |
| 5 | `enable_btf=false` 撞闸门 1 | 基线 `DEBUG_INFO_BTF=y`，fragment 写 `=n` 属覆盖 | 闸门 1；改为合并后 `scripts/config -d` |
| 6 | 27 个符号静默消失（BPF_LSM / 硬件性能计数器 / UPROBES） | 调试裁剪含 `CONFIG_PROFILING` | 实测对比：加则 27 个掉，不加则正好 15 个 |
| 7 | 模块签名是 SHA-1、无 `MODULE_SIG_PROTECT` | 手写 defconfig 基线不对 | 日志人工核对 |
| 8 | `.github/` 不进版本库 | `.gitignore:13` 的 `.*` 把它吞了 | `git status` |
| 9 | workflow 触发失败 | `ref: main`，但本仓库唯一分支是 `oss` | CI 报错 |
| 10 | AK3 在 BakaSU 里刷不进 | 上游 `tools/` 是 32 位 ARM，SM8735 不执行 AArch32 | 实机；见 §7.2 |

第 6 条最值得警惕：**内核照样编译成功，只是功能没了。**
没有任何编译期信号能发现它，只有对比实测数字才能。

---

## 9. 已知未解决

| 项 | 影响 | 现状 |
|----|------|------|
| **`Module.symvers` CRC 未比对** | 刷进去能开机 **≠** 原厂 `vendor_dlkm` 模块都能加载。这才是 vendor 模块加载的真正决定因素 | 需要从设备取一份基线 `Module.symvers` 来比对 |
| 内核版本串 | 显示为 `6.6.82-4k-gbe04d83ab2e2-dirty` | `CONFIG_LOCALVERSION_AUTO=y` + 工作流改了源码。仅观感问题 |
| `fetch-depth: 0` | checkout 190 s | ReSukiSU `setup.sh` 的前置要求；未测试浅克隆是否可行 |
| vendor `=y` 过滤偏粗 | `INPUT_FINGERPRINT` / `FOD_FINGERPRINT` 是空壳 | 见 §5.6 |
| ccache 命中率低 | 7.15% | 缓存来自一次在配置阶段就失败的运行，键已污染；多跑几次会回升 |
| DTB 打包分支 | 死代码 | 见 §7.5 |
| AK3 实机验证 | **未做** | CI 只能证明包能生成，刷不刷得进去只有实机能证明 |

## 10. 暂未移植

`BBRv3`、`NTSYNC`、`Baseband-guard` —— 6.6.82 里没有这些特性，
`kernel_xiaomi_sm8735` 的 6.6.82 也没有对应的上游实现可搬。

---

## 11. 维护提示

**改 fragment 前先读** `onyx_gki.fragment` 顶部的两条规则——它们不是建议，
是闸门 1 和闸门 3 的直接后果：

1. 绝不要设基线里已经是 `=y` 或 `=m` 的符号 → merge_config 报 override → 构建失败。
2. 绝不要设依赖无法满足的符号 → `olddefconfig` 静默丢弃 → 闸门 3 失败。

一句话：**fragment 里的每一行，都是对内核会遵守它的承诺。**

**BTF 两条铁律**（写进 `onyx_debug_reduction.fragment` 顶部了）：

- `CONFIG_DEBUG_INFO_BTF` 必须保持开。
- `CONFIG_DEBUG_INFO_REDUCED` 必须保持关。

**改 `tools/` 前先读** `anykernel/AK3-NOTES.md` 的表格。
只更新脚本，**永远不要**从上游 master 取二进制。

---

## 12. 提交历史

```
8702d7358702  ak3: restore aarch64 tools, upstream master only ships 32-bit ARM
b6c7068b8f44  ak3: update AnyKernel3 to upstream 020dfec, clean up packaging
be04d83ab2e2  config: cut SUSFS fragment to the two known symbols, drop UAPI_HEADER_TEST
9e0b3b6b5fca  config: KSU_SUSFS_SUS_PATH is a bool, revert to =y
43c0984ebcaa  ci: make the config gates self-protecting, drop write permission
da2e27a5cace  ci: switch to official Kleaf config synthesis, restore BTF
9b5fa60c2b82  ci: fix modpost failure, enable SUSFS, honour make exit code
54c52cf9b191  ci: add build-onyx workflow (Capybara tuning on onyx GKI)
```

从下往上看就是完整的演进史：先从 gki-clo 移植，再修 modpost 和 SUSFS，
再把配置合成换成官方方式（顺带修好 BTF 和模块签名），再收紧权限，
最后修 AK3 架构回归。
