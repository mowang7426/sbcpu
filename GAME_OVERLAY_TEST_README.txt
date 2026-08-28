SBCPUFloating 2.9.1 游戏内弹幕通知测试版

功能：
1. SpringBoard 继续负责捕获微信/QQ/TIM 通知。
2. 当前前台游戏若注入 SBCPUGameOverlay.dylib，会通过 CFMessagePort 收到通知。
3. 通知以细长胶囊横幅从屏幕右侧滑入，停留约 2.6 秒，再向左侧滑出。
4. Overlay 的 window 和 banner 都不接收触摸，不应该阻挡游戏操作。
5. 游戏窗口绑定当前 UIWindowScene，避免 iOS 13+ 创建窗口但不显示。
6. 一次多条通知进入队列，按顺序显示。

注意：
- GameOverlay 当前采用白名单，只注入 SBCPUGameOverlay.plist 中列出的游戏。
- 如果要测试的游戏不在白名单，需要把其 Bundle ID 加进去。
- 第一阶段只验证“游戏内显示”，不做点击通知跳转聊天。
