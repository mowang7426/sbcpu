# SBCPUFloating V3.1

- 修复 Tweak.xm 中 Thermal Notification 状态页面使用 `pressure` 变量先使用后声明导致的 clang 编译错误。
- 保留原有强制 120Hz 功能。
- 新增 `SBCPUFloatingCC` 控制中心模块子工程，安装到 `/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle`。
- 控制中心开关与 `SBCPUFloating.enabled` 同步，并通过 Darwin notification 通知 SpringBoard 立即刷新。
- GitHub Actions 会检查最终 DEB 是否真的包含控制中心 Bundle。

注意：第三方控制中心模块的显示依赖设备上实际负责加载第三方模块的 CCSupport/兼容控制中心管理器。Theos 官方提供 iOS 11+ Control Center module 模板，CCSupport 用于加载第三方模块。
