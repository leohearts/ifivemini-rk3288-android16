# iFive mini 4S (RK3288) Android 16 移植 —— 最终技术报告（2026-11-07）

平板：iFive mini 4S，RK3288（4 核 Cortex-A12 32 位，MIDR 410fc0d1）、2 GB 内存、Mali-T760、1536×2048 双 DSI 屏、Ricoh RC5T619 电源芯片，原厂 Android 6。
目标：装上新版 Android，修掉 bug 和性能问题，最后留一个稳定的 Android 16。

最终留在平板上的版本：`release/ifive-mini4s-android16-gsi-2026-11-07.zip`（sha256 791935d6…）。

---

## 1. 系统是怎么搭起来的

**内核**：原厂是 3.10，我们把 4.19 移植到了这块板子上（源码在 `ksrc-touch`，分支 chg-cur）。触摸、Wi-Fi（bcmdhd）、音频、摄像头、电源芯片、重力传感器（lsm330）、显示（Rockchip DRM/VOP + DSI）都是在这个内核上调通的。

**启动方式**：沿用 Rockchip 的 loader。kernel / resource（设备树+logo）/ ramdisk 三个分区用 Rockchip 的 KRNL 容器格式打包（`release/build/tools/mkkrnl.py`，CRC 是 Rockchip 自己的变种，多项式 0x04C10DB7）。分区表由设备树里的 `blkdevparts` 决定。

**Android 本身**：
- Android 11：第三方 Android 11 vendor（不是原厂的，原厂只有 Android 6；vendor 的原始来源记录随报告目录丢失，现在查不到）+ A11 系统，system 分区 1536 MiB。
- Android 12 / 16：GSI（Android 16 用的是 TrebleDroid 的 a64_bvS），放在 3072 MiB 的 super 分区里，vendor 还是上面那套第三方 A11 vendor。
- 因为两种布局的分区位置不一样，11-05 曾经把 GSI 的包配上了 A11 的 resource，平板卡了一整夜。之后写了 `guard-release.py`，打包时检查 super 装不装得下、flash 脚本里的扇区号和 resource 里的分区表是否一致。

**两个版本内核配置上的差别**：A16 必须开 `BPF_JIT_ALWAYS_ON`，否则开机卡死；A11 开了反而卡死。所以 A11 和 GSI 用两个发布内核。NetBpfLoad 会报一个 "CRITICAL FAILURE"（arm32 JIT 不支持 BPF_XADD），确认只是日志，不影响使用。

---

## 2. 修掉的 bug

### 重力感应 / 自动旋转
两层问题：内核里 lsm330 驱动的 sensor_active 没把芯片真正打开（修后 CTRL_REG5 读出 0x67）；A11 的 vendor 里有一个 overlay 把 `config_supportAutoRotation` 设成了 false，改成 true 重新签名。A12/A16 上旋转按钮正常。

### 充电电流
现象：插 2 A 充电头只充 500 mA。原因：电源芯片的充电器检测说是 DCP，USB PHY 说是 SDP，驱动按 SDP 限了 500 mA。
按你的要求，不把 2 A 做成默认值：
- 内核默认 500 mA；只有 `high_current_allowed=1` 时才按口型提升（SDP 500 mA / CDP 1.5 A / DCP 2 A），并且电池温度 < 40 ℃、电压 ≥ 3.5 V 才提；40–45 ℃ 降到 1 A，≥ 45 ℃ 回 500 mA，每 30 秒重新判断。
- JEITA 温度保护按原厂方式（软件模式，原厂设备树的温度/电流档位）移植进了驱动。
- 开机后由一个 vendor 服务 `chgpolicy.sh` 根据 `persist.vendor.chg.boost`（auto/on/off，默认 auto）决定要不要提升，条件：电池 < 40 ℃、SoC < 70 ℃、电量 < 95%。
- 今天验收时发现这个服务一直没启动：init 的 rc 里没写 `seclabel`，init 拒绝做域切换。加上 `seclabel u:r:vendor_shell:s0` 后正常，开机后 ADP 限流变成 2000000。
- 关机充电：release 的设备树加回了 CW2015 电量计节点、去掉 uboot-charge，`reboot -p` 插着充电头 90 秒不会开机，通过。

### 画面卡顿（主要的性能工作）
A16 上 Settings 滑动 38–42% 掉帧，p50 42 ms。查下来不是 CPU 频率也不是内存，是合成方式：Rockchip 的 HWC1（走 HWC2on1 适配器）每一帧都把所有图层退回 GPU 合成（CLIENT）。原因在 HWC 的 `mix_policy`：SurfaceFlinger 的"静态画面优化"把每一层都打上 skip 标记，HWC 遇到 skip 范围覆盖全部图层就整体放弃硬件合成。
修法（`hwc/src-a16`，提交 ab3afb5）：skip 范围覆盖全部图层时清掉标记再试一次平面匹配，失败才回退。之后全部图层走 VOP 硬件合成（DEVICE），首次测得掉帧 2–6%，p50 20 ms。
代码审查发现这样匹配上的图层没拿到 fence（可能撕裂/复用未完成的 buffer），补了 fence 修复（c0eea98）。今天热启动下 A/B：带 fence 修复 5–20% 掉帧、p50 21–25 ms；不带的那次测到 50%（这个基准本身波动很大，参考价值有限）。最终 release 用的是带 fence 修复的版本（sha 83101dff）。

其它试过但没收益的：ART 预编译 Settings（无变化）、调度器/GPU 频率固定（无变化）、分辨率降到 1152×1536（掉帧 43% → 28%，没采用）、Vulkan 和主线内核 panfrost（T760 不支持 PanVK，放弃）。

### Power HAL
A16 开机日志里 "Could not find android.hardware.power.IPower" 拖慢了 SurfaceFlinger 启动。把 `android.hardware.power-service.rockchip` 加进 vendor，`class hal` 让它在 late-init 启动，开机后 20 秒就绪。

### 屏幕亮度
每次开机后自动设成手动模式、亮度 20，这是你的要求，写进了验收脚本。

---

## 3. 死机问题——做了什么、查到哪

**现象**：首次开机或长时间运行后偶尔整机硬死（屏幕停住、USB 消失），平板自己回不来。

**先解决"回得来"**：写了一个内核驱动 `rk_wdt_backstop`：
- 测试版镜像有定时复位（300/1500 秒）和看门狗；复位时把 loader 标志写进 PMU 寄存器，机器直接进 maskrom，电脑可以接着刷。
- 死机前的内核日志每 5–20 秒写进 kpanic 分区（`rklogdump`），事后用 `gsi/parse-logdump.py` 读出来。
- 今天验证了硬件看门狗：所有 CPU 关中断死循环后十几秒内复位，`CRU_GLB_RST_ST` 从 0x00 变成 0x22（看门狗复位位），确认是看门狗干的。
- 正式版不带定时复位和看门狗（`rkwdt=0`），只带 kpanic 日志。
- 屏幕上加了 fbcon（`console=tty0`），死机时屏幕上就是内核日志。

**查到的**：
- 以前记录的"死机"大多数是电脑这边 adb 卡住没列出设备（kpanic 日志里 boot_completed 都在）。今天 6 轮调试内核首次开机全部正常。
- 真正有现场的只有 11-06 23:23 那次 A12：日志停在 86.7 秒，init 正在启动 netd/wificond，没有内核报错。
- 11-03 抓到过一次 Oops：idle 路径里函数返回地址被改写（栈/寄存器损坏），写入者不明。
- 排除掉的：BPF JIT（程序里没有子程序调用）、Cortex-A17 errata（CPU 实际是 A12，A12 的 errata 已开）、Wi-Fi 驱动（死机时段处于断电）、CPU 电压（696 MHz 曾低于原厂，已改回 1.05 V）。
- 根因没有定论。现在电脑上有一个被动监视（`rk3288-hangwatch.service`）：平板再死、你进一次 maskrom，它会自动把 kpanic 读出来解析，不刷不动。

---

## 4. 没做成的：HWC2
为了去掉 HWC2on1 适配器的开销，把 Rockchip 的 drmhwc2（lineage-23.2 分支）移植编译成功并上过机。它能开机、能用，但初始化其实没完成（`init_success_=0`），主平面一直留着 fbcon 的画面，熄屏再亮屏就看到 fbcon——这就是你看到的问题。强制 RK3288 平面分配的修法让所有平面绑不上 CRTC，已经撤回。在它上面测的 CPU 数据作废。

---

## 5. 最终 release 里有什么
- super：td16n（A16 GSI + A11 vendor + HWC1 fence 修复 + Power HAL + 充电策略服务）。
- 内核：kernel-release-rl5bj（BPF_JIT_ALWAYS_ON，kpanic 日志，无看门狗/定时复位）。
- resource：release 设备树（关机充电、reboot-mode、触摸 I2C 400 kHz、fbcon 参数）。
- 原厂 loader，`flash.sh`（校验 SHA256SUMS、按 GSI 布局写入并回读比对），README。
- 验收：用包里的 flash.sh 刷，首次开机 adb 282 秒、boot_completed 314 秒；熄屏/亮屏 3 次正常；触摸、Wi-Fi、扬声器、重力感应、充电提升全部检查过；亮度 20。

---

## 6. 还没做 / 已知问题
- 硬死机根因未定（监视已布置）。
- HWC2 没做成；现在的 HWC1 方案掉帧在 5–20% 之间波动。
- A11 / A12 的发布包：今天清理磁盘时它们的 super 被删了，要重做得从 `rk3288-backup` 的原厂分区重新拼 vendor。
- 报告目录在清理时被误删（btrfs 开了 discard，找不回来），这份报告和 STATUS-1107.md 是凭今天的记录重写的。

## 7. 主机侧今天的事故（记一下，免得再犯）
- 两个脚本同时往 loader 写 super，loader 卡住；之后中途杀掉一个正在写的脚本又卡了一次，要你断电重进。现在所有设备脚本都走同一个锁。
- 子代理往 /tmp（内存盘）放了 4.3 GB，systemd-oomd 把 Thunderbird、Edge、plasmashell 和设备链一起杀了。已清。
- 清理 Data 盘时把报告目录一并删了。

磁盘：Data 盘可用空间从 50 GB 到 112 GB；`rk3288-a11/` 现在 12 GB。
