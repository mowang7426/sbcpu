# SBCPU V4.28 — CH0I/CH0C Recovery Fix

## 修复内容

V4.27 修复 AppleSMC 168-byte ABI 后，实测“阻止外部供电”已经可以成功写入 CH0I=1，但恢复外部供电失败，并提示“未检测到外部电源”。

根因是恢复路径错误地复用了“启用阻止”时的安全检查：

- CHCE 必须为外部电源已连接
- CH0R bit1 必须不是 No VBUS
- OBC 状态必须满足写入条件

当 CH0I=1 强制外部供电阻断后，SMC 可能暂时把 CH0R bit1 表示为 No VBUS，即使充电线物理上仍然插着。旧代码因此拒绝执行 CH0I=0，导致卡死在阻止外部供电状态。

## V4.28 行为

- `smc_set_power_block(true)`：仍保留 CHCE / CH0R 安全检查，只允许在真实外部电源状态下开启阻断。
- `smc_set_power_block(false)`：进入独立恢复路径，直接读取并清除 CH0I bit0，不再因为 CHCE / CH0R / OBC 状态拒绝恢复。
- `smc_set_charge_block(false)` 同样采用恢复专用路径，避免停充状态下 CH0R 状态变化导致“恢复充电”失败。
- 恢复仍经过完整 AppleSMC ABI 与 SMC result 检查；写失败会记录明确日志。

该恢复策略与 Battman 的 restore command 一致：恢复时直接写 `CH0I=0` 和 `CH0C=0`。同时保留启用阻断时的安全限制。

## 测试顺序

1. 插入有线充电器。
2. 打开“阻止外部供电”。
3. 确认手机停止从外部供电。
4. 再点击“恢复外部供电”。
5. 应立即恢复正常外部供电。
6. 重复开关 3~5 次，确认不会卡死。
7. 再测试“阻止充电”开关的 ON/OFF。
8. 最后再测试智能停充。

首次测试建议保持 `Override OBC` 关闭。
