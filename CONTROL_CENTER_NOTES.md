# V3.0 控制中心开关

本版本基于 `SBCPUFloating_V3.0_from_sbcpu-main_fixed6.zip` 增加 Control Center 模块。

## 行为
- 控制中心按钮与现有 `isEnabled` 设置共用同一个 CFPreferences 键。
- 开启：显示悬浮窗。
- 关闭：隐藏悬浮窗。
- 不会修改 CPUthermal、ChargeBoost、Force Fast Charge、Force 120Hz 等其他设置。
- 控制中心、设置页、悬浮窗之间通过 `com.yourname.sbcpufloating.prefschanged` Darwin 通知同步状态。

## 依赖
第三方 Control Center 模块通过 CCSupport 加载，因此 control 增加了 `com.opa334.ccsupport` 依赖。
