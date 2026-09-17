# SBCPU V4.37 — 浮窗尺寸/充电电量/液态玻璃关闭回退修复

本版基于 V4.36.9。

修复：
1. 浮窗从折叠态展开时，禁止每秒 `updateFloatingSize()` 在动画中途抢改 bounds/transform，避免出现“已经打开后又扩大一下”的二次跳变。
2. 充电时电量主值固定显示 `XX%`，不再把 `+XXXmAh` 拼到同一 UILabel 导致 14pt 字体因 `adjustsFontSizeToFitWidth` 被压缩。充电会话增量移到电量副标题行。
3. 液态玻璃关闭时，恢复旧版 `UIBlurEffectStyleSystemMaterialLight` 泛白毛玻璃。备用 blur 始终存在于浮窗底层，开启液态玻璃时隐藏，关闭时显示，不再出现透明/看不清文字的情况。
4. 保持原有液态玻璃开启时的渲染路径不变，不增加第二层可见液态玻璃。

主要修改文件：
- `Tweak.xm`
