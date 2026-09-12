# ArcStatusBar

极简点阵状态栏越狱插件 —— 把 iOS 状态栏的信号 / WiFi / 电池图标替换为**点阵极简风格**：

- **信号** → 4 个圆点，按信号强度点亮
- **WiFi** → 弧形 + 中心点，弧长随信号变化
- **电池** → 细竖线 + 电量填充
- 启动时播放一次「点阵 → 弧形」形变动画（对应视频中的加载效果）

## 目标环境

| 项目 | 要求 |
|---|---|
| 设备 | iPhone 14 Pro Max (A16, arm64e) |
| 系统 | iOS 17.0 |
| 越狱 | Relaxin (基于 RootHide / roothide, rootless) |
| 包管理器 | Sileo |

## 目录结构

```
ArcStatusBar/
├── Makefile               # theos rootless 构建配置
├── control                # deb 包信息
├── Tweak.x                # hook 入口: _UIStatusBar*View
├── ArcStatusBarViews.h/.m # 自定义点阵/弧形/线性视图 + 动画
└── README.md
```

## 工作原理

iOS 13+ 的状态栏是 `_UIStatusBar` 架构（UIKitCore 私有框架），每个图标是一个
`_UIStatusBarItemView` 子类：

| 原生类 | 作用 | 本插件替换为 |
|---|---|---|
| `_UIStatusBarCellularSignalView` | 蜂窝信号 | `ASBDotSignalView`（4 点） |
| `_UIStatusBarWifiSignalView` | WiFi | `ASBArcWifiView`（弧形+点） |
| `_UIStatusBarBatteryView` | 电池 | `ASBLineBatteryView`（竖线） |

做法：hook 上述三个类的 `layoutSubviews` → 隐藏原生图标层 → 挂上自定义
`CAShapeLayer` 视图 → 通过 KVC（`_signalStrengthBars` / `capacity`）同步真实
信号强度与电量。未 hook 到（类名随 iOS 变化）时插件自动跳过，不影响系统。

## 编译（GitHub Actions 自动构建, 推荐）

把工程推到 GitHub 后, 仓库内置的 `.github/workflows/build.yml` 会在 macOS runner 上
自动编译, 一次产出**两个包**:

- `ArcStatusBar-rootless.deb` — 通用 rootless
- `ArcStatusBar-roothide.deb` — **Relaxin / RootHide 环境装这个** (路径 /var/jb)

去仓库 **Actions** 页 → 最新一次构建 → **Artifacts** 下载即可。

## 编译（本地, macOS/Linux 均可）

### 1. 安装 theos

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
echo "export THEOS=~/theos" >> ~/.zshrc   # 或 ~/.bashrc
source ~/.zshrc
```

### 2. 编译

```bash
cd ArcStatusBar
make package
```

生成 `packages/com.doubao.arcstatusbar_0.1.0_iphoneos-arm64.deb`。

> 若提示找不到 `libsubstrate.tbd`：Relaxin 基于 ellekit，可切换链接方式——
> 编辑 `Makefile`，把 `ArcStatusBar_LIBRARIES = substrate` 改为
> `ArcStatusBar_LIBRARIES = ellekit`（需先 `git clone https://github.com/theos/libellekit` 到 theos/lib）。

### 3. 安装到手机

```bash
make package install     # 需先 export THEOS_DEVICE_IP=手机IP, THEOS_DEVICE_PORT=22
```

或把 `.deb` 通过 Sileo / Filza 安装。安装后 **注销 (respring)** 生效。

## 真机调试

- 卸载: Sileo 中移除 ArcStatusBar 即可。
- 日志: 设备上 `log stream --predicate 'process == "SpringBoard"'` 或
  安装 `oslog` 查看。
- 若图标没有变化：用 **FLEX** / `cycript` 检查真实类名是否仍是
  `_UIStatusBarCellularSignalView` 等（iOS 17 个别版本可能改名），改 `Tweak.x`
  中的 hook 类名即可。

## 自定义

- **图标颜色**：自动跟随状态栏前景色（`tintColor`），浅色/深色壁纸自适应。
- **动画开关**：删除 `Tweak.x` 中 `%hook SpringBoard` 一段可关闭启动动画。
- **信号样式**：改 `ArcStatusBarViews.m` 中点的直径/间距/数量。

## 风险提示

- 越狱插件有系统级风险，安装前建议先备份（设置-通用-传输或还原）。
- 仅在你自己的设备上使用；部分 App 可能有越狱检测，Relaxin 的 RootHide
  环境已内置屏蔽能力，但个别检测严格的 App 仍可能受影响。
