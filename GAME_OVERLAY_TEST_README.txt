SBCPUFloating 2.9.2 游戏内消息横幅测试版

本版重点修复：
1. 不再使用独立 UIWindow，避免进入横屏游戏后画面旋转、缩放或变形。
2. 游戏内通知直接挂到游戏当前前台 UIWindow。
3. SpringBoard 与 GameOverlay 改用共享 plist + Darwin Notify 传递通知，避免部分 RootHide/Rootless 环境下 CFMessagePort 跨进程不稳定。
4. 横幅为顶部黑色胶囊，单独显示，不占用 CPU 浮窗区域。
5. 横幅默认显示约 3.2 秒，右侧/上方动画改为从顶部轻微滑入后退出。
6. Overlay 完全不接收触摸，不应影响游戏操作。
7. 游戏进程仍采用白名单，只注入 SBCPUGameOverlay.plist 中的游戏。
8. 游戏启动前已经存在的旧通知不会在刚进入游戏时重复弹出。

测试重点：
- 进入 QQ 飞车手游后，画面不能再出现 90 度旋转或整体变形。
- TIM/微信/QQ 新消息应在游戏顶部中央出现独立黑色横幅。
- CPU 浮窗继续保持原来的位置和功能。
- 游戏触摸操作应正常。
