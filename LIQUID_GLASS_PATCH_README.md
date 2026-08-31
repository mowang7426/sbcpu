# 液态玻璃（Liquid Glass）改造说明

> 针对 **SBCPUFloating V3.1.19 源码**（横屏模式开关修复版）的浮窗外观增强。
> 目标：让性能浮窗呈现 **iOS 26 液态玻璃**质感。

## 重要：V3 修复记录（装 V2 进安全模式请看这里）
- **崩溃原因**：V2 的"玻璃厚度层"用了 `insertSubview:belowSubview:_blurView.contentView`。
  `UIVisualEffectView.contentView` 是懒加载的，初始化早期还不是 `_blurView` 的直接子视图，
  而 `insertSubview:belowSubview:` 要求参照视图必须是子视图 → SpringBoard 启动即抛异常 → 安全模式。
- **修复**：已删除该行。玻璃厚度改为**不碰 UIVisualEffectView 内部结构**的纯 layer 方案
  （高光层/边缘光全部用 `addSublayer` 挂在 `_blurView.layer` 上，零崩溃风险）。
- 若你已装 V2 进安全模式：先点 **Exit Safe Mode** 恢复正常 → 卸载旧 deb → 安装本版 → Respring。

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

## V6：玻璃厚度层（解决 CABackdropLayer 太透明）
V5 的 CABackdropLayer  backdrop 模糊太透，在聊天/复杂背景上背景文字直接透过来与浮窗数据重叠，
可读性差。V6 在 backdrop 层之上、内容之下加一层**半透明白色 tint 层**（`glassTintLayer`，
白 42% alpha），模拟玻璃厚度：
- 遮挡/软化背景，浮窗数据清晰可读
- 仍保留玻璃通透感（不是纯色不透明底）
- `CALayer` 加到 `_blurView.layer`，zPosition=1，不碰 UIVisualEffectView 内部结构
- 折叠/展开/布局同步 frame/cornerRadius
- CABackdropLayer 失败时 tint 层也不创建，自动 fallback

**调参**：搜 `alpha:0.42f`，想更不透明就调大（0.5~0.6），想更通透就调小（0.25~0.35）。
想换玻璃颜色（比如深色玻璃）就改 `colorWithWhite:1.0f` 为其他颜色。

## V5：真正 iOS 26 液态玻璃（CABackdropLayer 原生 backdrop 模糊）
V4 用 `UIVisualEffectView` 模拟，模糊质量与 iOS 26 原生液态玻璃有差距。V5 直接引入
SBLiquidGlass 同款的 **`CABackdropLayer` 私有 API**（render-server 级 backdrop 模糊），
这才是 dock 栏液态玻璃的真正底层。

- **CABackdropLayer**：`NSClassFromString(@"CABackdropLayer")` 动态获取，配置
  `windowServerAware` / `groupName` / `groupNamespace` / `ignoresScreenClip` / `scale`
  等私有属性（全部 `@try` 保护），插入 `_blurView.layer` 最底层做真正 backdrop 模糊
- **成功后** `_blurView.effect = nil`，用 CABackdropLayer 替代 UIVisualEffect 模糊
- **失败 fallback**：任何私有 API 异常都 `@catch`，自动回退到 UIVisualEffectView 模糊，不崩
- specular 边缘高光增强：基础高光 `白0.50`、boost `白0.90`、边缘宽度 `1.25pt`
- 折叠/展开/布局全部同步 `glassBackdropLayer.frame/cornerRadius`

**注意**：CABackdropLayer 是私有 API，行为随 iOS 版本变化。若装 V5 后进安全模式，
先 Exit Safe Mode 卸载，回退到 V4（UIVisualEffectView 安全版）。建议先在测试环境验证。

## V4：dock 液态效果（移植 SBLiquidGlass specular 配方）
参考 SBLiquidGlass V1.1.0 的 Dock.x / LGLiveBackdropView 实现，浮窗玻璃改为其核心配方：
- **specular 边缘高光**：双层 CAGradientLayer（`白0.30 → 透明 → 白0.30` 的 45° 渐变）
  + boost 层（`白0.70` + `compositingFilter=overlayBlendMode` 提亮）
- **边缘 mask**：每层带 `clearColor背景 + blackColor边框(0.75pt) + 圆角` 的 CALayer mask，
  让渐变高光**只露出玻璃边缘一圈**（rim light），与 iOS 26 dock 一致
- **最外沿细亮描边**（1pt 白 55%）收边
- 模糊仍用已验证安全的 `UIVisualEffectView`（SystemThinMaterialLight），背景透出模糊
- 全部为 `addSublayer` 图层操作，不碰 UIVisualEffectView 内部结构，零崩溃风险

**为何不用 SBLiquidGlass 的 CABackdropLayer**：那是 iOS 26 私有渲染 API（`CABackdropLayer` +
CoreImage 高斯滤镜），只有系统材质视图可用，且与你若已安装的 SBLiquidGlass tweak 叠加易冲突。
本版用安全的 UIKit 层复刻其视觉（半透明 + specular 边缘高光），观感接近 dock。

**调参**（搜 `glassSheenLayer` / `glassBoostLayer`）：
| 参数 | 默认 | 说明 |
|---|---|---|
| `alpha:0.30f`（sheen 两端） | 0.30 | 边缘高光基础强度 |
| `alpha:0.70f`（boost 两端） | 0.70 | 高光提亮强度 |
| `borderWidth`（mask） | 0.75 | 边缘高光宽度（越大高光越宽） |
| `startPoint/endPoint` | (0,0)→(1,1) | 高光方向（45°） |
| `cornerRadius` | 20 | 圆角（插件设置可改） |

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
