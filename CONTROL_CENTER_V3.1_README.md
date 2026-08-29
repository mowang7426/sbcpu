# SBCPU Floating V3.1 — Control Center module

本版本基于原 `sbcpu-main` 工程制作，保留原有 SpringBoard Tweak、CPUthermal、ChargeBoost、Force Fast Charge、120Hz、通知管理和 Preference Bundle。

新增：
- `SBCPUFloatingCC.bundle`
- 安装路径：`/Library/ControlCenter/Bundles`
- 控制中心开关与主 Tweak 共用 `com.yourname.sbcpufloating` 的 `isEnabled`
- 点击开关后通过 Darwin notification `com.yourname.sbcpufloating.prefschanged` 通知 SpringBoard 立即刷新

控制中心模块使用 Theos 的 `iphone/control_center_module-11up` 所对应的 `CCUIToggleModule` 体系。
