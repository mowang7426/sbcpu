# SBCPUFloating V3.1 — Control Center Safe Toggle Fix

本版本基于当前 V3.1 工程修复控制中心开关点击后 SpringBoard 进入安全模式的问题。

## 保留
- 原有浮窗逻辑
- 原有 120Hz / ProMotion120Driver
- FPS 监测
- 原有充电增强 / 强制快充相关逻辑
- 原有温控与通知逻辑
- Control Center 模块注册方式

## 核心修复
1. Control Center 模块只通过 CFPreferences 修改 `isEnabled`。
2. 点击后只发送 Darwin notification。
3. SpringBoard 收到该通知后只重新读取 `isEnabled` 并执行 `applyVisibility()`。
4. 不再因为 Control Center 点击而完整执行 `LoadPreferences()`，从而避免在 CC 动画期间重复触发 120Hz、FPS、充电、温控等底层初始化。
5. CC 模块不再依赖 RootHide 路径扫描头文件，只使用本地字符串转换函数。

版本：3.1
