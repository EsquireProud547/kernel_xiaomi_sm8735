# build-onyx — Capybara 调优移植到 Xiaomi SM8735 (onyx) GKI 6.6.82

把 `gki-clo` 仓库的 `build-capybara.yml` 构建流水线移植到本仓库。
两个树同源（`android15-6.6` GKI），基线不同：gki-clo 是 **6.6.77**，本树是 **6.6.82**。

## 新增文件

| 文件 | 来源 | 说明 |
|---|---|---|
| `.github/workflows/build-onyx.yml` | 移植自 `build-capybara.yml` | 17 步，配置合成改为官方 Kleaf 方式 |
| `.github/actions/droidspaces_sysvipc.patch` | **按 6.6.82 重新生成** | 零 offset 零 fuzz |
| `.github/actions/fixup_susfs.sh` | gki-clo | 逐字节一致 |
| `anykernel/` | gki-clo | 修正了版本号字符串 |
| `arch/arm64/configs/onyx_gki.fragment` | **新增** | Capybara 调优（fragment 形式） |
| `arch/arm64/configs/onyx_debug_reduction.fragment` | **新增** | UBSan/debugfs 裁剪（`PROFILING` 已剔除，见下） |
| `arch/arm64/configs/onyx_susfs.fragment` | **新增** | ReSukiSU + SUSFS，条件合入 |
| `.github/actions/libbpf_strchr_const.patch` | **新增** | BTF 前提：修 libbpf 在新编译器下的 const 错误 |
| `.gitignore` | 修改 | 加 `!.github/` 例外（见下） |

## 直接复用的部分

runner/清盘/swap、依赖清单、Clang 工具链下载与缓存、ccache 三级 key、
ReSukiSU、SUSFS + fixup 脚本、Droidspaces kABI 补丁、编译命令、AnyKernel3 打包、
产物上传、swap 20GB、`archive: false` 不二次压缩。

## 改动及原因

### 1. 改用官方 Kleaf 配置合成，丢弃烘焙式 defconfig

合成链与 `build.config.msm.perf` + `build.config.msm.common` 一致：

```
arch/arm64/configs/gki_defconfig          官方 GKI 基线（786 行）
  + onyx_gki.fragment                     Capybara 调优
  + vendor/onyx_perf.config 的 =y 条目     设备内置项
  + onyx_susfs.fragment                   仅当 enable_susfs
  + onyx_autofdo.fragment                 仅当 AutoFDO profile 可用
  --merge_config.sh -m -r -y-->  onyx_gki_defconfig
  --裁剪（scripts/config，改 merged defconfig）-->  make onyx_gki_defconfig
```

并复刻了官方三道闸门（`build.config.msm.common`）：

| 闸门 | 官方位置 | 行为 |
|---|---|---|
| ① 覆盖冲突 | `:97` | fragment 改写了基线已有的 `=y/m` → `::error::` 失败 |
| ② kconfig warning | `:106` | defconfig 阶段出现任何 `warning:` → 失败 |
| ③ 片段生效校验 | `:125` | `diffconfig` 发现"被请求启用却没生效"的符号 → 失败 |

> **闸门③ 与官方有一处刻意偏差**：官方对任何非 `+` 行都失败，因为它 merge 之后
> 从不改配置。我们会做一次裁剪，关掉 `CONFIG_UBSAN` 会让其子项不可见，
> `diffconfig` 就会报 `-UBSAN_BOOL n` —— 那是"本来就未设置"，不是被丢弃的请求。
> 因此只对 `-SYM y` / `-SYM m` / `-SYM y -> m` 报错，其余按计数放过。

**fragment 只能新增，这是官方语义。** 想关掉基线已有的选项就不该写成 fragment，
所以裁剪单独做成 `onyx_debug_reduction.fragment`，在 merge 之后、`make` 之前
由 `scripts/config` 施加到 merged defconfig 上 —— 这样闸门③ 仍然是真实断言。

### 2. 合入 Xiaomi vendor 模块（只取 `=y`）

CI 里用 `scripts/kconfig/merge_config.sh` 合入 `arch/arm64/configs/vendor/onyx_perf.config`
（就是厂商构建 `build.config.msm.perf` 里 `apply_defconfig_fragment` 用的那份），
可由 `enable_vendor_modules` 关闭。

**只合入 `=y` 的 4 个条目**（`INPUT_FINGERPRINT` / `FOD_FINGERPRINT` /
`JOYSTICK_XPAD_FF` / `JOYSTICK_XPAD_LEDS`），`=m` 的 33 个 OEM 模块**故意不编译**：

```
ERROR: modpost: "qcom_smem_alloc" [drivers/power/supply/mca/.../mca_qcom_smem.ko] undefined!
ERROR: modpost: "pwrkey_irq_notifier_list" [drivers/mtd/mtdoops.ko] undefined!
```

原因是这些 OEM 模块链接的是 **vendor（msm-kernel）镜像导出的符号**，而那个镜像不在
本仓库里：

| 符号 | 定义处 | 需要 | GKI 配置里有吗 |
|---|---|---|---|
| `qcom_smem_alloc` | `drivers/soc/qcom/smem.c:521` | `CONFIG_QCOM_SMEM` | ❌ |
| `pwrkey_irq_notifier_list` | `drivers/input/misc/pm8941-pwrkey.c:93` | `CONFIG_INPUT_PM8941_PWRKEY`（`depends on MFD_SPMI_PMIC`） | ❌ |

厂商用的是 mixed-build：这些模块在 vendor 内核里编译，对着 KMI 符号表链接。
单树 GKI 构建做不到，所以只能不编。

**丢弃它们没有任何损失**：这些模块本来就不会被打进刷机包 —— 放进 AnyKernel3 需要重打
`vendor_dlkm`，超出范围。设备用的是 `vendor_dlkm` 里的原厂模块，我们只需要 `=y` 的那几项
（它们真的会进 Image）。过滤规则是从 fragment 动态推导的，小米以后加条目也不用改代码。

> 已在 Configure 步骤加了护栏：若将来 fragment 里某个 `=m` 条目又被启用，会在编译前
> 打出 `::warning::`，而不是等 25 分钟编译完才在 modpost 炸掉。

需要拿到 `.ko` 做手动测试时，打开 `bundle_modules`（会放进 zip 的 `modules/`，不参与刷写）。

### 3. Droidspaces kABI 补丁按 6.6.82 重生成

原补丁在 6.6.82 上是 `offset 1` + `fuzz 2` 打上的（`task_struct` 里
`ANDROID_KABI_RESERVE(8)` 之后被 `#ifdef CONFIG_RV` 打断，尾部上下文不再匹配）。
重生成后 `patch -p1 --dry-run` 零 offset 零 fuzz。

原理与验证：`sysvsem`/`sysvshm` 原本是插在 `task_struct` **中部**的，
直接开 `CONFIG_SYSVIPC` 会顶移后续所有字段 → 厂商模块读错偏移 → bootloop。
补丁把两者挪到 `ANDROID_KABI_RESERVE(6/7/8)` 的 u64 空洞上（union 覆盖）：

```
sizeof(struct sysv_sem) = 8   -> 占 1 个 slot (6)
sizeof(struct sysv_shm) = 16  -> 占 2 个 slot (7+8)
task_struct: size 不变、后续字段 offset 不变
```

本仓库 `ANDROID_KABI_RESERVE` 在 `drivers/android/Kconfig:81` 是 `default y`，
且 `ANDROID_KABI_USE` 不受 `CONFIG_ANDROID_KABI` 门控 —— 所以这个技巧开箱即用。

已实测：`kernel/sched/core.o`、`kernel/fork.o`、`ipc/{util,msgutil,msg,sem,shm,syscall,mqueue}.o`
全部真实编译通过（`exit=0`），说明 union 的 `_Static_assert` 全部满足。

### 4. 摘要不再谎报成功

gki-clo 的摘要无条件写 `AutoFDO | enabled`，但 AutoFDO 下载是显式非致命的。
本工作流把 `KSU_STATUS` / `SUSFS_STATUS` / `DROIDSPACES_STATUS` / `AUTOFDO_STATUS`
写进 `$GITHUB_ENV`，摘要只反映真实发生的事。

### 5. AnyKernel3 版本号不再过期

gki-clo 的 `anykernel.sh` 里 `kernel.string=Capybara CLO Kernel 6.2` 硬编码了 6.2
（实际 6.6.77），一直没人改。本工作流在打包时用真实
`out/include/config/kernel.release` 改写 `kernel.string` 与 `ui_print`，
不可能再过期。

### 6. `.gitignore` 必须改

本仓库 `.gitignore:13` 是 `.*`，会把整个 `.github/` 吞掉 —— 工作流文件根本进不了仓库。
已在 "don't ignore dot-files" 段落加 `!.github/` 系列例外
（并比 gki-clo 多覆盖了 `*.sh`，gki-clo 的 `fixup_susfs.sh` 是靠 `git add -f` 进去的）。

## 暂未移植（按要求）

| 功能 | 原因 | 移植所需 |
|---|---|---|
| **BBRv3** | 6.6.82 无 `net/ipv4/tcp_bbr3.c` | 从 gki-clo 拷 `tcp_bbr3.c` + `net/ipv4/Kconfig`(3 处) + `Makefile`(1 处) |
| **NTSYNC** | 6.6.82 无 `drivers/misc/ntsync.c` | 拷 `ntsync.c`(1218 行) + `include/uapi/linux/ntsync.h` + Kconfig + Makefile |
| **Baseband-guard** | 6.6.82 无 `security/baseband-guard` | 拷 14 个文件 + `security/Kconfig`、`security/Makefile`、`security/baseband-guard` 符号链接 |

`onyx_gki.fragment` 里没有相关条目 —— 一旦补齐源码，照上面的"移植所需"列添加即可。

## 输入参数

| 参数 | 默认 | 作用 |
|---|---|---|
| `enable_susfs` | `true` | 打 SUSFS 补丁（`gki-android15-6.6` 分支，匹配本树）并合入 `onyx_susfs.fragment` |
| `ksu_branch` | `main` | ReSukiSU 分支 |
| `version` | 空 | 自定义版本号，空则用 `github.run_number` |
| `enable_vendor_modules` | `true` | 合入 `onyx_perf.config` 的 `=y` 条目 |
| `enable_autofdo` | `true` | 用上游 GKI AutoFDO profile（失败自动跳过） |
| `enable_btf` | `true` | BTF（需 pahole ≥ 1.21；装不上或版本过低时自动降级为关闭，不失败） |
| `reduce_debug` | `true` | UBSan/debugfs 裁剪，施加在 merged defconfig 上 |
| `bundle_modules` | `false` | 把 `.ko` 放进 zip 的 `modules/`（不参与刷写） |

## 本地已验证

```bash
# 1) 官方合成链路 + 三道闸门（BTF 开 / 关两条路径都跑通）
export ARCH=arm64
F="arch/arm64/configs/gki_defconfig arch/arm64/configs/onyx_gki.fragment"
grep -E '^CONFIG_[A-Za-z0-9_]+=y$' arch/arm64/configs/vendor/onyx_perf.config > vendor_builtin.fragment
mkdir -p out/arch/arm64/configs
KCONFIG_CONFIG=$PWD/out/arch/arm64/configs/onyx_gki_defconfig \
  ./scripts/kconfig/merge_config.sh -m -r -y $F vendor_builtin.fragment   # 闸门①
# 裁剪（-d / -e 从 onyx_debug_reduction.fragment 解析）+ BTF 关闭项
./scripts/config --file out/arch/arm64/configs/onyx_gki_defconfig $OVERRIDE_ARGS
make O=out CC=clang LLVM=1 LLVM_IAS=1 onyx_gki_defconfig                   # 闸门②
./scripts/diffconfig out/arch/arm64/configs/onyx_gki_defconfig out/.config # 闸门③

# 结果（BTF 开）
#   HZ=300 / LTO_CLANG_THIN=y / ZRAM_DEF_COMP="lz4"
#   SYSVIPC=y / POSIX_MQUEUE=y / IPC_NS=y / PID_NS=y / DEVTMPFS=y
#   DEBUG_INFO_BTF=y / DEBUG_INFO_BTF_MODULES=y / PAHOLE_VERSION=132
#   MODULE_SIG_HASH="sha512" / MODULE_SIG_PROTECT=y
#   BPF_LSM=y / PERF_EVENTS=y / INPUT_FINGERPRINT=y

# 2) 两个补丁零 offset 零 fuzz
patch -p1 --dry-run < .github/actions/droidspaces_sysvipc.patch
patch -p1 --dry-run < .github/actions/libbpf_strchr_const.patch

# 3) 打 kABI 补丁后 sysvipc 目标文件真实编译通过
make O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 \
    kernel/sched/core.o kernel/fork.o ipc/sem.o ipc/shm.o ipc/mqueue.o
```

> SUSFS 那条路径**未在本地验证** —— 本树没有 SUSFS 的 Kconfig 符号，
> 闸门③ 会正确地判定其未生效并失败。CI 里补丁先落地，该路径才能走通。
> 这一点与其他已验证路径的差别是刻意的：闸门的存在就是为了让"没验证过"
> 的配置在合并阶段就暴露，而不是等刷机后才发现。

## 已知取舍

- **设备 DTS 缺失**：本树和 gki-clo 一样没有 SM8735/onyx 的 dtsi
  （`arch/arm64/boot/dts/qcom/` 下 381 个全是 legacy SoC）。所以产物走
  `Image.gz-dtb` → `Image.gz` → `Image` 的回退链，实际上命中 `Image.gz`
  （`init/Kconfig:267` 默认 `KERNEL_GZIP`）。设备树由设备侧 vendor 分区提供。
- **Clang 版本错配**：工具链取 `android17-release` 的 `clang-r596125`
  （约 kernel 6.12 世代），而内核是 6.6 世代，AutoFDO profile 取自 `android15-6.6`。
  与 gki-clo 一致，CI 里已验证可编译。
- `__ANDROID_COMMON_KERNEL__`（`build.config.common` 里的 KCFLAG）在本树源码中
  **零引用**，故未加入。

---

## BTF（eBPF / CO-RE）

官方 GKI 基线**本来就带** `CONFIG_DEBUG_INFO_BTF=y`。之前的烘焙式 defconfig
把它弄丢了，原因是一个元凶：

```
lib/Kconfig.debug:375  config DEBUG_INFO_BTF
                        depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
```

`onyx_defconfig` 里有 `CONFIG_DEBUG_INFO_REDUCED=y`，直接挡死 BTF，而且
`olddefconfig` **一声不吭**地丢弃。切回官方基线后自动恢复，实测：

```
CONFIG_DEBUG_INFO_BTF          = y
CONFIG_DEBUG_INFO_BTF_MODULES  = y
CONFIG_PAHOLE_HAS_BTF_TAG      = y     （pahole >= 1.23）
CONFIG_MODULE_ALLOW_BTF_MISMATCH = y   （关键，见下）
CONFIG_PAHOLE_VERSION          = 132
```

BTF 的三个前提都已处理：

1. **`DEBUG_INFO_REDUCED` 必须关** —— 裁剪片段里明确不碰它
2. **pahole >= 1.21**（DWARF5 门槛）—— CI 新增 `Install pahole for BTF` 步骤，
   装 `dwarves` 包并校验版本；版本过低时**降级为不启用 BTF**而非直接失败
3. **`tools/lib/bpf` 编译失败** —— `DEBUG_INFO_BTF` 会触发 `make prepare` →
   `resolve_btfids` → `tools/lib/bpf`，而它在新版宿主编译器上因 `strchr`
   的 const 正确性报错，且 `Makefile:89` 用 `override CFLAGS += -Werror` 无法用
   命令行标志绕过（试过 `HOSTCFLAGS` 和 `EXTRA_WARNINGS`，后者会污染 objtool）。
   改用 `.github/actions/libbpf_strchr_const.patch` 一行 cast，已验证零 fuzz。

### 为什么 `MODULE_ALLOW_BTF_MISMATCH` 是必需项而非可选项

`CONFIG_DEBUG_INFO_BTF_MODULES=y` 后，[kernel/bpf/btf.c:7373-7390](newwork/kernel_xiaomi_sm8735/kernel/bpf/btf.c:7373)：

```c
btf = btf_parse_module(mod->name, mod->btf_data, ...);
if (IS_ERR(btf)) {
    if (!IS_ENABLED(CONFIG_MODULE_ALLOW_BTF_MISMATCH)) {
        err = PTR_ERR(btf);            // ← 模块加载直接失败
    } else {
        pr_warn_once("... BTF mismatch ...");  // ← 只警告
    }
}
```

原厂 `vendor_dlkm` 模块是**对着官方 GKI 的 BTF** 编译的，我们的 vmlinux BTF
来自改了 HZ/LTO/Droidspaces 的内核，结构体布局必然有差异。官方基线已自带
`CONFIG_MODULE_ALLOW_BTF_MISMATCH=y`，沿用它即可。

### 附带修好的模块签名问题

烘焙式 defconfig 里是 `CONFIG_MODULE_SIG_SHA1=y`，官方基线是 `SHA512`。
二者在一个 `choice` 里**只能选一个**，而原厂模块是用 SHA-512 签的。
校验失败产生 `-ENOPKG`（非致命），最终是否放行取决于
`CONFIG_MODULE_SIG_PROTECT`（[signing.c:135-139](newwork/kernel_xiaomi_sm8735/kernel/module/signing.c:135)）。
旧配置**没有**这个选项，理论上会落到 `security_locked_down()` 被拒。
官方基线自带 `MODULE_SIG_SHA512` + `MODULE_SIG_PROTECT=y`，组合是正确的。

---

## 裁剪片段中为什么没有 `CONFIG_PROFILING`

gki-clo 的裁剪列表里有它。在本树实测，**关掉它会连带关掉 12 个符号**：

```
PROFILING → PERF_EVENTS → BPF_EVENTS → BPF_LSM
               |              |
               |              └→ UPROBE_EVENTS → UPROBES
               └→ HW_PERF_EVENTS → ARM_PMU / ARM_PMUV3 / HAVE_HW_BREAKPOINT
```

即**全部硬件性能计数器、uprobe 支持、BPF LSM 一起消失**，而内核照常编译通过。
这与"为 eBPF 配 BTF"的目标直接冲突。

实测对比：

| 裁剪清单 | 连带丢失符号数 | BPF_LSM / 性能计数器 |
|---|---|---|
| 含 `PROFILING`（gki-clo 原样） | **27** | ✗ 全部消失 |
| 去掉 `PROFILING`（当前） | 15，且全是我们主动关的那 15 项 | ✓ 完好 |

原列表被称为 "ABI-verified" —— 这话没错（不改动任何导出结构体），
但它悄悄砍掉了用户实际依赖的功能。
