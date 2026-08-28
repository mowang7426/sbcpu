SBCPUFloating V2.9.4 - GameMarquee IPC Path Fixed

本版针对 V2.9.2 测试截图继续修复：
1. 游戏内通知层不再创建独立 UIWindow。
2. Overlay 选择前台游戏中面积最大的正常 UIWindow，避免误挂到特殊/辅助窗口。
3. Overlay 与 Banner 设置极高 zPosition，确保位于游戏 UIKit 窗口最上层。
4. SpringBoard 与 GameOverlay 使用共享 payload + Darwin Notify。
5. GameOverlay 增加 0.35 秒轻量轮询作为 Darwin Notify 兜底，解决部分 RootHide/游戏进程组合下 Darwin 通知偶发丢失。
6. 对 payload timestamp 做去重，避免轮询导致同一条消息重复弹出。
7. 横竖屏变化时重新计算 Banner 位置，不主动修改游戏方向。
8. Banner 不接收触摸，游戏操作不被拦截。

重点测试：
- QQ飞车手游横屏进入后，游戏画面不能旋转/拉伸。
- TIM/微信/QQ 新消息到达后，游戏顶部出现独立黑色胶囊横幅。
- CPU 浮窗继续独立显示，不与游戏横幅合并。

注意：如果顶部仍出现游戏/系统自己的白色通知条，而黑色 GameMarquee 不出现，说明旧的系统通知 UI 仍在显示，但 GameOverlay 本身尚未收到/显示 payload；此时请提供截图和 build 日志。


V2.9.4 关键修复：
- 修复 GameOverlay.xm 与 Tweak.xm 使用不同共享 plist 路径的问题。
- SpringBoard 写入 /var/tmp/com.yourname.sbcpufloating.gameoverlay.plist，GameOverlay 现在从同一路径读取。
- 之前发送端和接收端路径分别是 /var/tmp 与 /var/mobile/Library/Preferences，导致游戏内 Banner 永远收不到 payload。
