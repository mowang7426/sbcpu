# 液态玻璃（Liquid Glass）改造说明

> 针对 **SBCPUFloating V3.1.19 源码**（横屏模式开关修复版）的浮窗外观增强。
> 目标：让性能浮窗呈现 **iOS 26 液态玻璃**质感。

## 改了什么

源码版本本来就有毛玻璃基础（`_blurView` = UIVisualEffectView + `SystemThinMaterialLight` 模糊 + 圆角 + 白描边），这次在它基础上补齐了液态玻璃最关键的**表面高光/反光**，并强化玻璃边缘。

| # | 位置 | 修改 |
|---|---|---|
| 1 | `@interface SBCPUFloatingView` | 新增 `glassSheenLayer`（CAGradientLayer）属性 |
| 2 | `initWithFrame:` | 创建液态玻璃**表面高光层**：45° 斜向白色渐变（顶亮→渐隐→微亮→无），`zPosition=1000` 保证始终盖在内容之上（玻璃表面反光） |
| 3 | `initWithFrame:` | 描边加亮：`borderWidth 0.5→0.8`，`borderColor 白60%→白78%`，边缘更有玻璃光感 |
| 4 | `updateLayoutWithShowCpuFreq:` | 布局完成后同步高光层 frame（展开/数据刷新时跟随） |
| 5 | `collapseToEdgeAnimated:` | 折叠为胶囊时同步高光层 frame（折叠态也是玻璃） |
| 6 | 全局默认值 | `floatingCornerRadius 默认 16→20`，更圆润的液态玻璃大圆角 |

> 说明：展开/折叠/拖动/通知弹出/启动动画均沿用原布局逻辑，只在其上叠加玻璃效果；不改任何数据逻辑。

## 液态玻璃效果组成（公开 UIKit API 模拟）

```
┌─────────────────────────────┐
│  亮白描边（玻璃边缘光）         │
│  ┌─────────────────────────┐ │
│  │  Surface 高光渐变层        │ ← CAGradientLayer（本补丁新增）
│  │  顶部亮 → 斜向渐隐 → 底部微光 │
│  │  ┌─────────────────────┐ │ │
│  │  │ contentView 数据内容   │ │ │ ← CPU/FPS/电量/温度/电流…
│  │  └─────────────────────┘ │ │
│  │  模糊材质 SystemThinMaterialLight │ ← 已有 _blurView
│  └─────────────────────────┘ │
│  柔和投影（shadow 0.18/12pt）   │
└─────────────────────────────┘
```

1. **模糊透出**：`SystemThinMaterialLight` 让桌面壁纸透进浮窗（已有）
2. **表面反光**：新增高光渐变层模拟玻璃在光照下的斜向反光
3. **边缘光感**：加亮的白色描边模拟液态玻璃边缘折射
4. **圆润大圆角**：默认 20pt

## 如何调参

打开 `Tweak.xm` 搜索 `glassSheenLayer`，在 `initWithFrame:` 的高光层定义处：

| 参数 | 说明 | 默认 |
|---|---|---|
| `alpha:0.28f`（第2个色） | 顶部反光强度 | 0.28 |
| `alpha:0.13f`（第3个色） | 中部过渡 | 0.13 |
| `_glassSheenLayer.opacity` | 整层强度（0~1） | 0.55 |
| `startPoint/endPoint` | 反光方向（当前左上→右下） | (0,0)→(1,1) |
| `_blurView.layer.borderWidth` | 描边粗细 | 0.8 |
| 圆角 | 插件设置里 `floatingCornerRadius` | 20 |

想更透就调低 `opacity`/顶部 alpha；想更"玻璃反光"就调高。

## 编译安装（macOS + Theos）

```bash
# 1. 安装 Theos（一次性）
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH

# 2. 编译
make clean && make package

# 3. 安装到越狱设备后 Respring
```

## 注意事项
- 仅改浮窗外观，不触碰性能采集/温控/快充等核心逻辑
- iOS 26 原生 Liquid Glass 的**动态折射/扭曲**由系统私有 API 驱动，公开 UIKit API 无法复现，本方案用"模糊+高光+描边"达到视觉近似，是越狱插件最稳的做法
- 若浮窗在深色壁纸上文字偏暗，可在插件设置里调浅文字颜色（原插件支持）
