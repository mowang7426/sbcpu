# SBCPUFloating V2.9.3 — CPUthermal 1.6.4-53 thermal-only integration

本版本以 `sbcpu-2.9.1 修复版 2` 为 UI/浮窗基线，移除旧的 SBCPU 温控控制链，并把 CPUthermal-1.6.4-53 的 `thermalmonitord` 核心温控引擎作为独立 `SBCPUThermal.dylib` target 集成。

## 已移除
- 旧 `SBCPUMitigation.dylib` / `MitigationHook.xm`
- SBCPU 自己的 CPU 温控等级/功率拦截
- 旧温控暗屏、温度计、口袋温度、阳光限制 Hook
- 旧高温智能断充
- 旧 SBCPU 自己的温控/充电联动逻辑（但保留原有强制快充功能本身）

## 保留
- 电池温度/电流显示（仅显示，不负责温控）
- 120Hz 开关（不再读取旧 `thermalProtectionEnable`）
- 原浮窗、通知、设置等 UI
- 原充电增强（实时验证）功能
- 原强制满血快充功能及其设置项/状态显示
- 强制快充底层的 ChargeCurrent / ChargeLimit / ChargeRate / ChargeInhibit 控制路径

## 新温控
`SBCPUThermal.xm` + `SBCPUThermalRecovered.mm` 来自用户提供的 CPUthermal 1.6.4-53-Source，偏好文件与 SBCPU 共用 `com.yourname.sbcpufloating`。

设置：
- CPUthermal 温控引擎
- 低功耗 / 解除温控
- 防温控暗屏
- 屏蔽高温温度计警告

## 本次修改原则
- **不修改 Tweak.xm 的浮窗创建、拖动、吸附、折叠、横屏自动展开、通知展示等布局逻辑。**
- 温控只由 `SBCPUThermal` 负责。
- `ChargeBoost` 保留原实现。
- `Force Fast Charge` 保留原开关与底层充电限制控制；仅把它接入新的 SBCPUThermal IOKit 层。

## 注意
本包是源码合并版，当前环境没有完整 Theos/iPhoneOS SDK，因此没有声称已经在 GitHub Actions 中编译通过。首次测试建议只安装源码构建后的 DEB，并准备好原 tweak 作为回滚。
