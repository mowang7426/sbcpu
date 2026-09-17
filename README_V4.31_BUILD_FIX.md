# V4.31 Build Fix

修复 V4.31 在 Theos 编译时的 `-Werror,-Wunused-but-set-variable` 错误。

`gCachedPowerBlocked` 只被赋值但没有读取，已删除该无效缓存变量及赋值。

本修复不改变智能停充 CH0I 回充逻辑，也不改变浮窗布局修复。
