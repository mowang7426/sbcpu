# SBCPU V4.30 — Smart Charge -> CH0I

本版按测试需求修改智能停充路径：

- 智能停充达到上限后，统一调用 `smc_set_power_block(true, overrideOBC)`。
- `gLimitUsesPowerBlock` 固定为 `true`。
- 降到下限后统一调用 `smc_set_power_block(false, overrideOBC)` 恢复外部供电。
- 中间滞回区持续回读 CH0I，若系统/OBC 清掉 bit0，则重新应用 CH0I=1。
- `keepAC` 不再决定智能停充是否使用 CH0C；字段保留用于旧 UI/协议兼容。
- 手动“阻止充电”和手动“阻止外部供电”仍保持原有独立逻辑。

测试建议：
1. 智能停充 ON，上限 85%，下限 70%，覆盖 OBC OFF。
2. 85% 触发后观察外部供电是否真正断开。
3. 85%+ 中间区间保持阻断。
4. 70% 以下恢复外部供电。
5. 再测试拔插电与 Respring。
