# SBCPUFloating V3.1.4 温控核心心跳修复

本版针对“设置页和悬浮窗始终显示温控核心未运行”进行修复。

## 修复
- 温控核心心跳改为 Unix 毫秒时间戳，生产端与读取端统一时间基准。
- 除 Darwin notify 外，温控核心每 3 秒写入 `/var/tmp/com.yourname.sbcpufloating.thermal.heartbeat`。
- SpringBoard 优先读取共享文件心跳，避免 RootHide 下跨进程 Darwin notify 状态不可见导致误判。
- 温控核心关闭时删除心跳文件，避免旧状态残留。
- 设置页和悬浮窗共用同一套实时心跳判断。

## 重要
本次仅修改“核心是否运行”的诊断链，不改变温控核心实际保护策略。
