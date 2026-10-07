# 灵动监测 4.87

- 显示名称改为「灵动监测」。`com.sbcpu.floating` 包名、设置域、通知名、动态库和控制中心标识不变，兼容已有配置与升级。
- 电池厂商读取原始 `Manufacturer` / `BatteryData.Manufacturer` 字段，处理字符串及 UTF-8 数据，不再缺失时默认 Apple。芯片上报无法可靠验证零售品牌或原装性；未知即显示未知。
- 充满时间优先使用有效系统值；系统未提供时，基于原始容量和持续 30 秒以上的正向净充入电流给出粗略时间区间。计入后段充电降流的余量；断电、未充电、已满、数据不足、波动和低电流均明确显示原因。重接充电器、读数间隔过长或电流反向会清空旧样本。估算只展示，不改变任何充电控制策略。
- 内存可用估算使用 `(HOST_VM_INFO64.free_count + inactive_count) × host_page_size`。XNU `free_count` 已含预读页（`speculative_count`），不重复相加；也不额外加入可能重叠的 `purgeable_count`。总容量读取真实值、不向上取整或默认 6GB，显示 MiB/GiB，读取失败不保留旧数据。
- 原照片裁切为 720px 无损母版，生成 29/58/87px 的 1x/2x/3x 设置和控制中心图标，并确保两套高清资源进入包内。没有凭空重建照片细节。
- 删除设置首页的 CPU/FPS、电池温度、通知聊天介绍和手势说明；实际单击、长按和拖动行为保留。
- 顶部状态胶囊不显示圆点，修复刷新把点重新打开的逻辑；普通折叠胶囊的圆点、尺寸、位置和动画不变，展开时不留折叠点。

## 回归验证

GitHub macOS：`tests/battery_metrics.m` 使用 Foundation 真实运行，并兼测 Objective-C++。
`tests/memory_metrics.c` 和 `tests/floating_display_policy.c` 使用标准 C 严格编译。
`tests/panel_branding.py` 检查源资源、旧标识兼容、说明区删除和打包后的高清倍率。

XNU 统计口径参考：<https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c>（`host_statistics64`）。
设备真值仍需用户安装后验证；硬件字段缺失时不伪造结果。
