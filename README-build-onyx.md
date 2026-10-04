# build-onyx — Capybara 调优移植到 Xiaomi SM8735 (onyx) GKI 6.6.82

把 `gki-clo` 仓库的 `build-capybara.yml` 构建流水线移植到本仓库。
两个树同源（`android15-6.6` GKI），基线不同：gki-clo 是 **6.6.77**，本树是 **6.6.82**。

## 新增文件

| 文件 | 来源 | 说明 |
|---|---|---|
| `.github/workflows/build-onyx.yml` | 移植自 `build-capybara.yml` | 15 步，结构一一对应 |
| `.github/actions/droidspaces_sysvipc.patch` | **按 6.6.82 重新生成** | 零 offset 零 fuzz |
| `.github/actions/fixup_susfs.sh` | gki-clo | 逐字节一致 |
| `anykernel/` | gki-clo | 修正了版本号字符串 |
| `arch/arm64/configs/onyx_defconfig` | 由 `capybara_defconfig` 改造 | 调优已烘焙进文件 |
| `.gitignore` | 修改 | 加 `!.github/` 例外（见下） |

## 直接复用的部分

runner/清盘/swap、依赖清单、Clang 工具链下载与缓存、ccache 三级 key、
ReSukiSU、SUSFS + fixup 脚本、Droidspaces kABI 补丁、编译命令、AnyKernel3 打包、
产物上传、swap 20GB、`archive: false` 不二次压缩。

## 改动及原因

### 1. 调优从 `sed` 改为烘焙进 defconfig

gki-clo 在 CI 里用 20 行 `sed` 改 `capybara_defconfig` 文本。这套方案脆弱：

```
实测：# CONFIG_LTO_CLANG_THIN is not set 这行在非 clang 环境下根本不存在
      （ARCH_SUPPORTS_LTO_CLANG 不满足时该 choice 不可见）
      → sed 静默失败 → 以为开了 ThinLTO 其实没有
```

本仓库的 `onyx_defconfig` 用 `scripts/config`（幂等）预先写好：

- `CONFIG_HZ_300` / `CONFIG_HZ=300`（原 250）
- `CONFIG_LTO_CLANG_THIN`（FullLTO 与 KCFI 冲突，见 gki-clo 提交 `98763e396491`）
- `CONFIG_ZRAM_DEF_COMP_LZ4` / `CONFIG_ZRAM_DEF_COMP="lz4"`（原 lzo-rle）
- Droidspaces 配置块：`SYSVIPC` `POSIX_MQUEUE` `IPC_NS` `PID_NS` `DEVTMPFS`
  `NETFILTER_XT_MATCH_ADDRTYPE` `USER_NS` `TMPFS_POSIX_ACL`

### 2. 合入 Xiaomi vendor 模块

CI 里用 `scripts/kconfig/merge_config.sh` 合入 `arch/arm64/configs/vendor/onyx_perf.config`
（就是厂商构建 `build.config.msm.perf` 里 `apply_defconfig_fragment` 用的那份），
可由 `enable_vendor_modules` 关闭。实测 22~34 个 `MI_*` / `XM_*` / `MCA_*` 符号全部解析为 `=m`。

> 注意：这些 OEM 模块构建出来后**不会**打进刷机包 —— 放进 AnyKernel3 需要重打
> `vendor_dlkm`，超出范围。它们的作用是让 GKI 配置面更接近厂商预期。
> 需要拿到 `.ko` 做手动测试时，打开 `bundle_modules`（会放进 zip 的 `modules/`，不参与刷写）。

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

`onyx_defconfig` 里已用 `# CONFIG_NTSYNC is not set  # TODO(port)` 标注。

## 输入参数

| 参数 | 默认 | 作用 |
|---|---|---|
| `enable_susfs` | `true` | 打 SUSFS 补丁（`gki-android15-6.6` 分支，匹配本树） |
| `ksu_branch` | `main` | ReSukiSU 分支 |
| `version` | 空 | 自定义版本号，空则用 `github.run_number` |
| `enable_vendor_modules` | `true` | 合入 `onyx_perf.config` |
| `enable_autofdo` | `true` | 用上游 GKI AutoFDO profile（失败自动跳过） |
| `bundle_modules` | `false` | 把 `.ko` 放进 zip 的 `modules/`（不参与刷写） |

## 本地已验证

```bash
# defconfig 在 6.6.82 上收敛，关键项全部存活
make O=out CC=clang LLVM=1 LLVM_IAS=1 onyx_defconfig
make O=out olddefconfig CC=clang LLVM=1 LLVM_IAS=1
#   CONFIG_HZ=300 / LTO_CLANG_THIN=y / ZRAM_DEF_COMP="lz4"
#   SYSVIPC=y / POSIX_MQUEUE=y / IPC_NS=y / PID_NS=y / DEVTMPFS=y
#   ANDROID_KABI_RESERVE=y

# vendor 片段合入
./scripts/kconfig/merge_config.sh -m -O out out/.config \
    arch/arm64/configs/vendor/onyx_perf.config

# kABI 补丁零 fuzz
patch -p1 --dry-run < .github/actions/droidspaces_sysvipc.patch

# 打补丁后 sysvipc 相关目标文件真实编译
make O=out CC=clang LLVM=1 LLVM_IAS=1 \
    kernel/sched/core.o kernel/fork.o ipc/sem.o ipc/shm.o ipc/mqueue.o
```

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
