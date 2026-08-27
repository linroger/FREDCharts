# FRED Ultra

A native macOS desktop app for searching, comparing, transforming, and exporting Federal Reserve Economic Data (FRED) time series. Built with SwiftUI and Swift Charts.

---

## 功能简介 | About

**FRED Ultra** 是一款专为经济研究设计的 macOS 原生桌面应用，可搜索、对比、变换和导出圣路易斯联储（St. Louis Fed）的 FRED 经济数据。

### 主要功能 | Key Features

| 功能 | 说明 |
|------|------|
| **API Key 引导** | 首次启动验证 FRED API Key，验证通过后保存至 macOS 钥匙串（Keychain） |
| **经济数据搜索** | 防抖搜索、结果高亮选中、近期查询与收藏序列 |
| **序列详情** | 关键指标、交互式图表、原始观测表、洞察卡片三个标签页 |
| **数据变换** | Level / Change / % Change / YoY % / Index (Start = 100) 五种变换 |
| **趋势线** | 可选的移动平均叠加线，窗口长度随数据频率自动缩放 |
| **多序列对比** | 单位兼容时统一量纲；单位不兼容时自动切换为指数化对比，并计算相关系数 |
| **数据导出** | CSV / JSON 导出与剪贴板复制，内容与屏幕所见完全一致 |
| **统一日志** | 覆盖搜索、详情加载、网络、导出与设置操作 |

---

## 系统要求 | Requirements

- macOS 15 (Sequoia) 或更新版本
- Xcode 16 或更新版本（本地开发；项目使用 Swift 6 语言模式）
- 免费 FRED API Key：[申请地址](https://fred.stlouisfed.org/docs/api/api_key.html)

---

## 项目结构 | Project Structure

```
FRED-Ultra/
├── FRED-Ultra/
│   ├── Models/
│   │   ├── FREDModels.swift        # API DTO、日期处理、频率、收藏
│   │   ├── Units.swift             # 单位解析与数值格式化
│   │   ├── Analytics.swift         # 变换、统计、相关性、降采样
│   │   └── DisplayModels.swift     # 时间窗口、变换、图表点、表格行
│   ├── Services/
│   │   ├── FREDService.swift       # API 客户端、缓存、重试
│   │   ├── SettingsManager.swift   # 凭据、收藏、近期搜索
│   │   └── ExportService.swift     # CSV / JSON / 剪贴板 / 保存面板
│   ├── Support/
│   │   ├── AppLogger.swift         # 统一日志分类
│   │   ├── KeychainStore.swift     # 钥匙串读写
│   │   └── AppCommandCenter.swift  # 菜单命令与详情页的桥接
│   ├── ViewModels/
│   │   ├── SearchViewModel.swift
│   │   └── SeriesDetailViewModel.swift
│   ├── Views/
│   │   ├── SeriesDetailView.swift
│   │   └── SettingsView.swift
│   ├── ContentView.swift           # 引导 / 侧边栏 / 详情工作区
│   └── FRED_UltraApp.swift         # 应用入口与菜单命令
├── FRED-UltraTests/                # 单元测试（47 个）
├── FRED-UltraUITests/              # UI 冒烟测试
├── script/
│   ├── xcode-env.sh                # 定位可用的 Xcode 工具链
│   └── build_and_run.sh            # 构建并运行
├── init.sh                         # 构建 + 测试健康检查
└── handoff.md                      # 交接文档
```

---

## 核心架构 | Architecture

### 数据流

```
用户输入 API Key
       ↓
SettingsManager  ──►  Keychain（回退到 UserDefaults）
       ↓
FREDService (actor)  ──►  完整历史数据缓存 15 分钟
       ↓
SeriesDetailViewModel
       │
       └─ 完整历史 → 单位换算 → 变换 → 时间窗口 → 指数化 → 派生状态
       ↓
SwiftUI Views（图表 / 表格 / 洞察）
```

**关键设计：** 每个序列的完整历史只下载一次，之后切换时间窗口和变换均在本地完成，不产生任何网络请求。

---

## 运行方式 | Running the App

### Xcode

1. 打开 `FRED-Ultra.xcodeproj`
2. 选择 `FRED-Ultra` scheme
3. Build and Run (⌘R)

### 终端

```bash
./script/build_and_run.sh            # 构建并运行
./script/build_and_run.sh --verify   # 构建、运行并确认进程已启动
./script/build_and_run.sh --logs     # 构建、运行并实时查看应用日志
./script/build_and_run.sh --build-only
```

脚本会自动定位可用的 Xcode（包括 `Xcode-beta.app`），无需 `sudo xcode-select`。若系统只安装了 Command Line Tools，脚本会给出明确的修复指引。

---

## 验证命令 | Verification Commands

```bash
./init.sh          # 构建 + 全部测试

# 或手动执行：
xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra \
  -destination 'platform=macOS' build

xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra \
  -destination 'platform=macOS' -only-testing:FRED-UltraTests test
```

---

## 键盘快捷键 | Keyboard Shortcuts

| 快捷键 | 功能 |
|--------|------|
| ⌘R | 重新下载当前序列 |
| ⇧⌘E | 导出 CSV |
| ⇧⌘C | 复制可见数据到剪贴板 |
| ⌘, | 打开设置 |

未打开任何序列时，Data 菜单中的命令会自动置灰。

---

## 数据变换说明 | Transforms

| 变换 | 计算方式 | 输出单位 |
|------|----------|----------|
| **Level** | 原始发布值 | 序列自身单位 |
| **Change** | 与上一期的绝对差 | 序列自身单位 |
| **% Change** | 与上一期的百分比变化 | Percent |
| **YoY %** | 与最接近一年前那一期的百分比变化 | Percent |
| **Index (Start = 100)** | 以窗口内第一期为 100 重新基准化 | Index |

- 增长率类变换在**完整历史**上计算，再截取时间窗口，因此窗口内第一个点也是真实计算结果，而非被丢弃的行。
- YoY 通过**日期匹配**而非固定行偏移查找一年前的观测，因此对工作日频率、含缺失值、频率变更过的序列同样正确。
- 指数化在截取窗口**之后**执行，基准始终是用户当前看到的第一期。

---

## 单位与对比 | Units & Comparison

- **单位家族**：货币、百分比、指数、人数、通用。
- **可比性**：`Billions of Dollars` 与 `Current U.S. Dollars` 可比（统一换算为美元）；`Chained 2017 Dollars` 与名义美元**不可比**，因为价格基准不同。
- **不可比单位**：添加对比序列时若单位不可比，应用会自动切换到 `Index (Start = 100)` 并给出提示；若用户已手动选择过变换，则尊重用户选择并显示警告，绝不把不同量纲画在同一坐标轴上。
- **相关系数**：对比模式下计算主序列与各对比序列的 Pearson 相关系数，按最近日期对齐（月度 vs 季度等不同频率也能正确配对）。

### 单位标注

图表按人类可读量级缩放（`Billions of Dollars` → `$29.0T`），因此图表标注的是 **U.S. Dollars**；数据表与导出保留 FRED 的**原始发布值**（`29,016.714`），标注为 **Billions of Dollars**。两处标签分别描述各自实际显示的内容。

---

## 数据存储 | Data Storage

| 数据 | 位置 |
|------|------|
| API Key | macOS 钥匙串（若钥匙串不可用，回退至 `UserDefaults`，并在设置中明确标注） |
| 收藏序列 | `UserDefaults`，键名 `FRED_FAVORITES` |
| 近期搜索 | `UserDefaults`，键名 `FRED_RECENT_SEARCHES`（最多 12 条） |
| 观测数据缓存 | 仅内存，15 分钟有效期，可在设置中清除 |

旧版本存储在 `UserDefaults` 中的 API Key 会在首次启动时自动迁移到钥匙串并删除明文副本。

应用仅与官方 FRED API（`api.stlouisfed.org`）通信，不上传任何数据至第三方服务器。

---

## 统计指标说明 | Statistics

| 指标 | 说明 |
|------|------|
| Latest | 窗口内最新读数 |
| Latest Change | 相比上一期的变化（百分比序列以 pp 为单位） |
| Period Change | 窗口内首末期之间的总变化 |
| Annualized Drift | 复合年化增长率（仅在 Level 变换、首末值同号且为正时计算） |
| Range Position | 最新值在窗口最低/最高值之间的位置 |
| Volatility | 可见观测的标准差 |
| Latest vs Average | 最新值相对窗口均值的标准分（z-score） |
| Max Drawdown | 窗口内最大回撤（仅在全为正值的 Level 序列上计算） |

指标无法定义时显示 `n/a`，不会用占位数字冒充数据。

---

## 性能 | Performance

- **单次下载**：每个序列的完整历史只请求一次（FRED 单次最多返回 100,000 条观测，覆盖其全部序列；最长的日度序列约 17,000 条）。
- **本地窗口化**：切换时间范围、变换、趋势线均为纯本地计算。
- **图表降采样**：单序列超过 1,500 个点时使用 LTTB（Largest-Triangle-Three-Buckets）降采样，保留峰值与拐点；数据表和导出始终保留全部行，界面会明确提示。
- **表格惰性构建**：数据表行仅在需要时构建并按状态版本缓存。
- **重试与限流**：429 与 5xx 采用有界指数退避重试（0.6s / 1.8s），远低于 FRED 每分钟 120 次的配额。

---

## 已知限制 | Known Limitations

- 搜索结果上限为 50 条，暂不支持翻页。
- 观测数据缓存仅存在于内存中，应用重启后需要重新下载。
- 相关系数按最近日期对齐计算，频率差异极大的序列（如日度 vs 年度）应谨慎解读。
- UI 测试中的启动截图用例在无 Accessibility 授权的无头环境下会自动跳过。

---

## 许可与数据来源 | License & Attribution

数据来源：Federal Reserve Economic Data (FRED)，Federal Reserve Bank of St. Louis。使用前请阅读 [FRED 数据使用条款](https://fred.stlouisfed.org/legal/)。
