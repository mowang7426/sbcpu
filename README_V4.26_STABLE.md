# SBCPU V4.26 Charge Engine Stable

这份工程是在 `SBCPU-V4.25-ChargeEngine-修复版` 上直接修复，不是重新搭一个空项目。原有 SBCPU Floating / Thermal / Control Center / Force120 目标保留。

## 本版实际修复

1. 修复 `IOServiceInterestCallback` 为原生四参数签名。
2. `SBCPUChargeSMC.m` 的 `smc_read_key()` 不再因为 SMC dataSize 大于调用者 buffer 而越界 memcpy。
3. CH0C / CH0I 的 cache 只做优化，实际 SMC 当前位始终作为权威状态；系统在休眠、拔插电或 OBC 接管后把 bit 改掉时，daemon 会重新收敛。
4. Charge Engine 增加递归 mutex，串行化 IOKit 电源事件和 socket 命令。
5. 修复 daemon 重启后 `gLimitBlocked` 丢失导致旧 CH0C/CH0I 状态残留的问题。
6. 修复上限/下限/keepAC 配置运行中改变后状态机继续沿用旧决定的问题。
7. 修复 manual block 内存状态在 SMC 操作失败时提前写入的问题。
8. OBC override 使用 Battman 同样的 mobile CFPreferences 写法，并检查关闭 OBC / CH0B 写入错误。
9. `SBCPUPowerd.xm` 不再伪造 CurrentCapacity、Temperature、Voltage、CycleCount、MaxCapacity、FullyCharged 等电池状态，也不再拦截 ChargeInhibit / ChargeBlocked / ChargeLimit。它只保留可选的充电电流/功率限制辅助。
10. postinst 不再 `nohup` 启第二个 daemon，避免 launchd 实例和手动实例竞争。
11. PreferenceBundle 增加两个真正可进入的页面：`充电管理`、`充电限制`。设置修改后直接通知 ChargeDaemon 立即重新判断。

## 第一轮真机测试建议

先使用：

- 智能充电：开
- 上限：80%
- 下限：70%
- 保留外部电源：开
- 覆盖 OBC：关
- 手动阻止充电：关
- 手动阻止外部供电：关

测试顺序：

`75 → 80 → 79 → 75 → 70`

预期：

- 80%：CH0C bit0 = 1
- 79% / 75%：继续保持停充
- 70%：CH0C bit0 = 0

然后测试：

`80% 停充 → 拔掉充电器 → 重新插入时 75%`

重新插入后应该继续保持限制。

最后做一次 respring，再观察 daemon 是否继续工作。

## 注意

`覆盖 OBC` 是单独的实验选项，第一轮不要打开。

当前版本的 `充电计划/开始时间/直到` 仍未接入 Charge Engine，不要把预留字段当成已经实现的功能。

## GitHub Actions

项目原有 `build.yml` / `build_fixed.yml` 保留。推荐使用 `build_fixed.yml` 手动触发，确认 RootHide Theos + iPhoneOS 16.5 SDK 后执行 `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`。
