# build-onyx

用 GitHub Actions 构建 **Xiaomi SM8735 (onyx) GKI 6.6.82** 内核，套用 Capybara 调优，
产出可直接刷入的 AnyKernel3 zip。

流水线移植自 `gki-clo` 仓库的 `build-capybara.yml`。两个树同源（`android15-6.6` GKI），
基线不同：gki-clo 是 **6.6.77**，本树是 **6.6.82**。

**当前状态：CI 首次完整出包成功。** 18 步全绿，耗时 22.6 分钟（构建 947s），
产物 19 MB，三道配置闸门 3/3 通过，BTF 已启用（pahole 1.31）。

---

## 文件清单

| 文件 | 来源 | 说明 |
|---|---|---|
| `.github/workflows/build-onyx.yml` | 移植自 `build-capybara.yml` | 17 步，配置合成改为官方 Kleaf 方式 |
| `.github/actions/droidspaces_sysvipc.patch` | **按 6.6.82 重生成** | 零 offset 零 fuzz |
| `.github/actions/fixup_susfs.sh` | gki-clo | 逐字节一致 |
| `.github/actions/libbpf_strchr_const.patch` | **新增** | BTF 前提：修 libbpf 在新编译器下的 const 错误 |
| `arch/arm64/configs/onyx_gki.fragment` | **新增** | Capybara 调优 |
| `arch/arm64/configs/onyx_debug_reduction.fragment` | **新增** | UBSan/debugfs 裁剪（`PROFILING` 已剔除） |
| `arch/arm64/configs/onyx_susfs.fragment` | **新增** | ReSukiSU + SUSFS，条件合入 |
| `anykernel/` | **上游 [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) @ `020dfec`** | 版本号改为打包时动态写入 |
| `.gitignore` | 修改 | 加 `!.github/` 例外（见下） |

---

## 配置合成

### 合成链

与 `build.config.msm.perf` + `build.config.msm.common` 一致：

```
arch/arm64/configs/gki_defconfig          官方 GKI 基线（786 行）
  + onyx_gki.fragment                     Capybara 调优
  + vendor/onyx_perf.config 的 =y 条目     设备内置项
  + onyx_susfs.fragment                   仅当 enable_susfs
  + onyx_autofdo.fragment                 仅当 AutoFDO profile 可用
  --merge_config.sh -m -r -y-->  onyx_gki_defconfig
  --刻意改写（scripts/config）-->  make onyx_gki_defconfig
```

### 三道闸门

复刻自 [build.config.msm.common](newwork/kernel_xiaomi_sm8735/build.config.msm.common)：

| 闸门 | 官方位置 | 行为 |
|---|---|---|
| ① 覆盖冲突 | `:97` | fragment 改写了基线已有的 `=y/m` → `::error::` 失败 |
| ② kconfig warning | `:106` | defconfig 阶段出现任何 `warning:` → 失败 |
| ③ 片段生效校验 | `:125` | `diffconfig` 发现"被请求启用却没生效"的符号 → 失败 |

闸门 ① ③ 各有一次真实拦截记录（见下文"闸门抓到的三个 bug"），② 也有一次。

### 两处刻意偏离官方

**1. 片段只能新增 → 需要两处 merge 后的改写**

官方 merge 之后不再碰配置；我们有两处必须改写基线已有的值：

- **调试裁剪**（15 项）—— 基线本身有 `PROFILING=y`、`UBSAN=y` 等
- **BTF 关闭**（3 项）—— 基线有 `DEBUG_INFO_BTF=y`，用 fragment 写 `=n` 会直接撞闸门 ①

所以这两处走 `onyx_debug_reduction.fragment`（保持声明式）+ 在 merge 后、`make` 之前由
`scripts/config` 施加到 merged defconfig 上。AutoFDO 同理，挪到 merge 之前做成 fragment ——
这样 merge 之后**没有任何 `scripts/config` 改动**，闸门 ③ 才是真断言。

**2. 闸门 ③ 的判据放宽**

官方对任何非 `+` 行都失败。我们关掉 `CONFIG_UBSAN` 会让子项不可见，`diffconfig` 会报
`-UBSAN_BOOL n` —— 那是"本来就未设置"，不是被丢弃的请求。因此只对 `-SYM y` / `-SYM m` /
`-SYM y -> m` 报错，其余按计数放过（实测放过 9 个）。

### 与"完全官方"的差距

| 层面 | 状态 |
|---|---|
| 合成**机制** | ✅ 官方 |
| 配置**基座** | ✅ 官方，`gki_defconfig` 原文件未动一个字节 |
| 配置**闸门** | ⚠️ 2 道逐字复刻，1 道判据放宽 |
| 配置**内容** | ❌ 调优必然是我们的 |

关键差距：**本树没有 GKI 侧的总 fragment**。官方 onyx/perf 在本树可见的完整片段链只有
`gki_defconfig + vendor/onyx_perf.config`；GKI 的 HZ/LTO 取值来自 Kleaf 侧
`build/kernel` 仓库的 `gki.fragment`，**那个文件不在本仓库**。纯基座收敛后是
`HZ_250 + LTO_NONE`，而我们的 `onyx_gki.fragment` 设 `HZ_300 + ThinLTO`。
ThinLTO 有硬理由（KCFI 与 FullLTO 冲突），但 **HZ 300 是否等于原厂取值无法从本仓库证实**。

---

## 闸门抓到的三个 bug

保留在这里作为"文本校验式闸门确实有用"的记录。

**① `KSU_SUSFS_SUS_PATH` 类型错误**（闸门 ②）

```
warning: symbol value '"/system/susfs"' invalid for KSU_SUSFS_SUS_PATH
```

我假定它是 string 并写了路径值。实际是 bool。gki-clo 原来的 `=y` 本来就对。
**教训：无法联网核实的假设，不该写进配置。**

**② 三个 SUSFS 符号在本分支不存在**（闸门 ③）

```
-KSU_SUSFS_HAS_MAGIC_MOUNT y
-KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_KSU_DENYLIST y
-KSU_SUSFS_SUS_OVERLAYFS y
```

从 susfs4ksu `gki-android15-6.6` 取到权威 Kconfig（`kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`）
后发现，这三个是旧版本遗留；而真实的 10 个子选项**全部 `bool ... default y`**。
片段因此精简到只剩 `CONFIG_KSU=y` + `CONFIG_KSU_SUSFS=y`。

**③ `CONFIG_PROFILING` 的连带损伤**（gating 之前的静默事故）

关掉 `PROFILING` 会经由 `PROFILING → PERF_EVENTS → BPF_EVENTS → BPF_LSM` 级联，
另外还干掉 `HW_PERF_EVENTS`（ARM_PMU / ARM_PMUV3 / HAVE_HW_BREAKPOINT）和
`UPROBE_EVENTS` / `UPROBES`。实测**丢失 27 个符号**，而内核照常编译通过、无任何提示 ——
这与"为 eBPF 配 BTF"的目标直接冲突。去掉 `PROFILING` 后只丢主动关的那 15 项。

---

## BTF

官方 GKI 基线**本来就带** `CONFIG_DEBUG_INFO_BTF=y`。之前的烘焙式 defconfig 弄丢了它，
原因是一个元凶：

```
lib/Kconfig.debug:375  config DEBUG_INFO_BTF
                        depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
```

`DEBUG_INFO_REDUCED=y` 直接挡死 BTF，而且 `olddefconfig` **一声不吭**地丢弃。

### 三个前提

1. **`DEBUG_INFO_REDUCED` 必须关** —— 裁剪片段明确不碰它
2. **pahole ≥ 1.21**（DWARF5 门槛）—— CI 装 `dwarves` 并校验；版本过低时**降级为
   不启用 BTF** 而非失败（本次实测 v1.31，附带 `BTF_TAG`）
3. **`tools/lib/bpf` 编译失败** —— `DEBUG_INFO_BTF` 触发 `make prepare` →
   `resolve_btfids` → `tools/lib/bpf`，而它在新版宿主编译器上因 `strchr` 的 const
   正确性报错，且 `Makefile:89` 用 `override CFLAGS += -Werror` 无法用命令行标志绕过
   （`HOSTCFLAGS` 被 override；`EXTRA_WARNINGS` 能修好 libbpf 但会污染 objtool）。
   改用一行 cast 的 patch，零 fuzz。

### 产物里确实有 BTF

`Image` 由 `objcopy -O binary` 生成（[arch/arm64/boot/Makefile](newwork/kernel_xiaomi_sm8735/arch/arm64/boot/Makefile)），
直觉上 BTF 属于 debug 段会被剥掉。但 [scripts/link-vmlinux.sh:130-135](newwork/kernel_xiaomi_sm8735/scripts/link-vmlinux.sh:130) 明确：

```sh
# Add SHF_ALLOC because .BTF will be part of the vmlinux image.
${OBJCOPY} --only-section=.BTF --set-section-flags .BTF=alloc,readonly
```

`.BTF` 被显式标为 alloc，所以 `-O binary` 会保留；运行期
[btf.c:5721](newwork/kernel_xiaomi_sm8735/kernel/bpf/btf.c:5721) 的 `btf_parse_vmlinux()`
经 `__start_BTF`/`__stop_BTF` 取用。**`/sys/kernel/btf/vmlinux` 会存在，CO-RE 可用。**

### `MODULE_ALLOW_BTF_MISMATCH` 是必需项

`DEBUG_INFO_BTF_MODULES=y` 后，[kernel/bpf/btf.c:7373-7390](newwork/kernel_xiaomi_sm8735/kernel/bpf/btf.c:7373)：
模块 BTF 校验失败时，若 `MODULE_ALLOW_BTF_MISMATCH` 未开则 `err = PTR_ERR(btf)` →
**模块直接加载失败**。原厂 `vendor_dlkm` 是对着官方 GKI 的 BTF 编译的，我们的 vmlinux
BTF 来自改了 HZ/LTO/Droidspaces 的内核，结构体布局必然有差异。官方基线自带该选项，沿用即可。

---

## 附带修好的模块签名问题

烘焙式 defconfig 里是 `CONFIG_MODULE_SIG_SHA1=y`，官方基线是 `SHA512`。二者在一个
`choice` 里**只能选一个**，而原厂模块是用 SHA-512 签的。校验失败产生 `-ENOPKG`（非致命），
最终是否放行取决于 `CONFIG_MODULE_SIG_PROTECT`（[signing.c:135-139](newwork/kernel_xiaomi_sm8735/kernel/module/signing.c:135)）。
旧配置**没有**这个选项，理论上会落到 `security_locked_down()` 被拒。官方基线自带
`SHA512 + MODULE_SIG_PROTECT=y`，组合正确。

> 这条只做了配置层推导，**没在真机上验证过**。

---

## Xiaomi vendor 片段（只取 `=y`）

`vendor/onyx_perf.config` 里 33 个 `=m` 的 OEM 模块链接的是 **vendor（msm-kernel）镜像**
导出的符号，那个镜像不在本仓库：

| 符号 | 定义处 | 需要 | GKI 配置里有吗 |
|---|---|---|---|
| `qcom_smem_alloc` | `drivers/soc/qcom/smem.c:521` | `CONFIG_QCOM_SMEM` | ❌ |
| `pwrkey_irq_notifier_list` | `drivers/input/misc/pm8941-pwrkey.c:93` | `CONFIG_INPUT_PM8941_PKEY` | ❌ |

厂商用 mixed-build，这些模块在 vendor 内核里对着 KMI 符号表链接；单树 GKI 做不到。
过滤规则从 fragment 动态推导，小米以后加条目不用改代码。

### 已知局限：过滤偏粗

4 个 `=y` 条目里，`JOYSTICK_XPAD_FF` / `JOYSTICK_XPAD_LEDS` 是**真实生效**的
（`JOYSTICK_XPAD` 是标准内核驱动，基座里已编入）。但这两个是**空壳**：

- `INPUT_FINGERPRINT=y` —— 框架在，但使用它的驱动 `FINGERPRINT_MI_FP=m` 被过滤掉了
- `FOD_FINGERPRINT=y` —— 同上

实测 `FINGERPRINT_MI_FP` **能独立链接**（exit 0），可以加入白名单。但白名单里的每个模块
都必须验证能链接，否则整个构建会在 modpost 失败。

---

## 其他

- **Droidspaces kABI 补丁**：`sysvsem`/`sysvshm` 原本插在 `task_struct` 中部，直接开
  `CONFIG_SYSVIPC` 会顶移后续字段。补丁挪到 `ANDROID_KABI_RESERVE(6/7/8)` 的 u64 空洞上
  （union 覆盖），`ANDROID_KABI_USE` 不受 `CONFIG_ANDROID_KABI` 门控，开箱即用。
  已实测 `ipc/{util,msgutil,msg,sem,shm,syscall,mqueue}.o` 真实编译通过。
- **摘要不谎报**：`KSU_STATUS` / `SUSFS_STATUS` / `DROIDSPACES_STATUS` / `AUTOFDO_STATUS` /
  `BTF_STATUS` 写进 `$GITHUB_ENV`，摘要只反映真实发生的事。
- **AnyKernel3 版本号**：打包时用真实 `out/include/config/kernel.release` 改写
  `kernel.string`。gki-clo 那个硬编码的 "6.2" 一直没改。见下节。
- **权限**：`contents: read`。纯构建工作流不需要写权限，而依赖侧是
  `curl ... | bash`（ReSukiSU `main`）加 susfs4ksu 移动分支。
- **`.gitignore`**：`:13` 的 `.*` 会吞掉整个 `.github/`。已加 `!.github/` 系列例外
  （比 gki-clo 多覆盖 `*.sh`，那边是靠 `git add -f` 进去的）。

---

## AnyKernel3

脚本已更新到上游 **`020dfec`（2026-09-04，"tools: update magisk utils to v31.0 beta"）**。
更新前那份来自 gki-clo。

> ⚠️ **二进制必须保持 aarch64，不能从上游 master 更新。** 详见
> [anykernel/AK3-NOTES.md](anykernel/AK3-NOTES.md)。

### ⚠️ 上游 master 只装 32 位 ARM —— 这个坑踩过一次

上游 README 明说：

> "The AK3 repo includes current **ARM builds** … Builds for **other
> architectures** … are available from the latest Magisk zip, or my latest
> AIK-mobile and FlashIt packages"

一次性把 `tools/` 全部换成上游版本后，**7 个二进制从 aarch64 全变成 32 位 ARM**：

| 工具 | 更新前 | 更新后（上游 master） |
|---|---|---|
| busybox / magiskboot / magiskpolicy | **aarch64** | ARM 32-bit |
| fec / httools_static / lptools_static / snapshotupdater_static | **aarch64** | ARM 32-bit |

SM8735 是 Oryon 核心，**不支持 AArch32**，32 位 ARM 二进制直接 `exec format
error`。在 KSU 管理器里的表现尤其明确——BakaSU 内置 AK3 刷入器
（`userspace/ksud/src/anykernel3.rs`）会在 `update-binary` 的
`chmod -R 755 tools bin;` 锚点前注入：

```sh
cp -f '<BIN>/mkbootfs' "$AKHOME/tools/mkbootfs" || exit 1;
```

该锚点在 `setup_bb()` 里位于 `$bb ` 之后，所以注入后展开成：

```sh
$bb cp -f ... || exit 1;
```

`$bb` 就是 `tools/busybox`。32 位 busybox 无法执行 → `|| exit 1` 立刻触发 →
**刷入中止**。

**修复**：脚本保持新版，7 个二进制恢复为 aarch64。兼容性已核对——新版
`ak3-core.sh` 调用的 magiskboot 子命令是旧版的**子集**（少了 `magiskboot
supports`），所以旧 aarch64 二进制完全够用。

刷新 aarch64 二进制的正确来源是 Magisk release 或 osm0sis 的 AIK-mobile /
FlashIt 包，更新后务必 `file tools/*` 确认每项都是 `ARM aarch64`。注意上游
`setup_bb()` 的架构探测只找 `tools/x86` 和 `tools/arm`，**没有 `tools/arm64`
分支**，所以 aarch64 二进制必须直接放在 `tools/` 下。

### 为什么不只是换工具

上游提交 `cea8f97`（"AK3+Backend: remove all backwards compat"）**删掉了小写变量名**。
新版 `ak3-core.sh` 只读大写：

| 旧（gki-clo / 更新前） | 新（必须） |
|---|---|
| `block=` | `BLOCK=` |
| `is_slot_device=` | `IS_SLOT_DEVICE=` |
| `ramdisk_compression=` | `RAMDISK_COMPRESSION=` |
| `patch_vbmeta_flag=` | `PATCH_VBMETA_FLAG=` |
| `no_magisk_check=` | `NO_MAGISK_CHECK=` |

实测新版 `ak3-core.sh` 里小写名出现次数为 **0** —— 只换工具而保留旧 `anykernel.sh`
会让 `BLOCK` 为空，刷机静默失败。所以两者必须同时更新，`anykernel.sh` 已按新 API 重写。

`BLOCK=boot` 仍是合法的（[ak3-core.sh:959](newwork/kernel_xiaomi_sm8735/anykernel/tools/ak3-core.sh:959)
用 `plistboot` 列表按名查分区），`IS_SLOT_DEVICE=auto` 也仍支持
（[ak3-core.sh:886](newwork/kernel_xiaomi_sm8735/anykernel/tools/ak3-core.sh:886)）。

### 打包命令

按上游 README "Building" 第 5 步执行：

```sh
zip -r9 UPDATE-AnyKernel3.zip * -x .git README.md *placeholder
```

- **`*.md` 排除** —— 上游 `README.md` 与本仓库的 `AK3-NOTES.md`，都是开发文档，刷机时无用途
- **`*placeholder` 排除** —— 只是为了让空目录能进 git；**目录本身必须保留**，
  `ak3-core.sh` 期望解包后存在 `ramdisk/` 和 `patch/`
- **`LICENSE` 保留** —— 上游明确要求："must remain in the final zip to comply with
  licenses for binary redistribution and the license of the AK3 scripts"

最终包内 23 项，含 `Image.gz`、`anykernel.sh`、`LICENSE`、`META-INF/`、`tools/`。

### 设备适配

保留了我们自己的设备逻辑，其余按上游模板：

```sh
do.devicecheck=0      # 不锁机型，GKI Image 通用
do.modules=0          # 不带 .ko（见 vendor 片段一节）
do.systemless=0
BLOCK=boot;  IS_SLOT_DEVICE=auto;  PATCH_VBMETA_FLAG=auto;  NO_MAGISK_CHECK=1;

if [ -L .../init_boot_a ]; then
    split_boot; flash_boot;   # 有 init_boot 分区的设备只换内核，不动 ramdisk
else
    dump_boot;  write_boot;   # 传统 boot 分区
fi
```

`ui_print` 那行已移除：新版 `update-binary:547-548` 自己会读 `kernel.string` 并打印，
脚本里再写一遍是多余的（更新前的文件里就有这么一行冗余，随本次一并清掉）。

---

## 输入参数

| 参数 | 默认 | 作用 |
|---|---|---|
| `enable_susfs` | `true` | 打 SUSFS 补丁并合入 `onyx_susfs.fragment` |
| `ksu_branch` | `main` | ReSukiSU 分支 |
| `version` | 空 | 自定义版本号，空则用 `github.run_number` |
| `enable_vendor_modules` | `true` | 合入 `onyx_perf.config` 的 `=y` 条目 |
| `enable_autofdo` | `true` | 用上游 GKI AutoFDO profile（失败自动跳过） |
| `enable_btf` | `true` | BTF（需 pahole ≥ 1.21；装不上或过低时降级为关闭，不失败） |
| `reduce_debug` | `true` | UBSan/debugfs 裁剪，施加在 merged defconfig 上 |
| `bundle_modules` | `false` | 把 `.ko` 放进 zip 的 `modules/`（不参与刷写） |

---

## 构建表现

| 阶段 | 耗时 |
|---|---|
| Checkout | 190s（最大单项，`fetch-depth: 0` 拉 2.75 GiB 全历史） |
| 清盘 + swap | 173s |
| **Build** | **947s** |
| 其余 15 步 | ~55s |
| **合计** | **22.6 分钟** |

swap 建 19 GiB，**用量 0 B**（内存充裕，ThinLTO 未吃到 swap 压力）。

**ccache 首次命中率仅 7.15%**（249/3484）—— 恢复的缓存来自上一轮在配置阶段就失败的任务，
它从未进入编译。本次已存下 3484 条新条目，**下一轮同配置应显著提升**。

---

## 已知未解决

- **`Module.symvers` CRC 校验未做。** 当前只证明"能出包"，**不证明原厂 `vendor_dlkm`
  模块一定能加载** —— 那取决于产物 CRC 与原厂是否一致。需要从设备上取 stock
  `Module.symvers` 作基线才能补这一步。
- **内核版本串带 `-dirty`。** `CONFIG_LOCALVERSION_AUTO=y` 加上工作流修改了被 git 跟踪的
  文件所致。功能无害（模块 vermagic 走 CRC，不看 `uname`），但干净检出构建会得到
  `6.6.82-4k`（无 SHA），两者不一致。消除方式：设 `CONFIG_LOCALVERSION_AUTO=n` + 固定
  `LOCALVERSION`。
- **checkout 的 190s。** `fetch-depth: 0` 是 ReSukiSU `setup.sh` 的前提（它对内核仓库做
  stash/checkout），改成浅克隆有风险，需单独验证。

---

## 暂未移植

| 功能 | 原因 | 移植所需 |
|---|---|---|
| **BBRv3** | 6.6.82 无 `net/ipv4/tcp_bbr3.c` | 拷 `tcp_bbr3.c` + `net/ipv4/Kconfig`(3 处) + `Makefile`(1 处) |
| **NTSYNC** | 6.6.82 无 `drivers/misc/ntsync.c` | 拷 `ntsync.c`(1218 行) + `include/uapi/linux/ntsync.h` + Kconfig + Makefile |
| **Baseband-guard** | 6.6.82 无 `security/baseband-guard` | 拷 14 个文件 + `security/Kconfig`、`security/Makefile`、`security/baseband-guard` 符号链接 |
