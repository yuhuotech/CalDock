# CalDock

轻巧的原生 macOS 菜单栏日历。Swift + AppKit + SwiftUI 实现，无 Electron、WebView、第三方依赖或后台服务。

要求 macOS 14 或以上。Bundle ID：`com.yuhuo.caldock`。

## 使用

构建并打开：

```sh
bash scripts/build-app.sh
open build/CalDock.app
```

安装到应用程序：

```sh
bash scripts/install-app.sh
open /Applications/CalDock.app
```

已完成 Developer ID 签名、Hardened Runtime 和 Apple 公证，票据已装订；主程序与 Widget 均为 arm64 / x86_64 Universal。公证凭据使用本机钥匙串配置 `caldock-notary`，不保存在仓库中。构建脚本自动选择当前团队的 Developer ID，缺少证书时明确报错；设置 `CALDOCK_SIGN_IDENTITY` 可选择证书。`CALDOCK_SIGN_IDENTITY=-` 仅供隔离开发，不保证 App Group 共享及已有系统授权可用。

- 点击菜单栏的当日日期图标打开月历，右键打开设置、关于与退出菜单。
- 默认全局快捷键 `⌃⌘X`，在通用设置中可以重新录制。
- 面板内 `←` / `→` 切换月份，`↑` / `↓` 移动日期一周，空格回到今天，Esc 关闭。
- 点击月份标题跳转年月；按住 Option 点击月份箭头可切换年份。
- `A` 展开或收起日程，`P` 固定面板，`⌘,` 打开设置。
- 右键某天可复制日期或打开系统日历。

## 功能

- 紧凑六周月历、农历、传统节日、常用公历节日和二十四节气。
- 2026 年官方放假和补班角标；未收录年份不猜测调休。
- 系统日历事件圆点、跨天事件、当天日程、日历筛选与新建事件。
- 通用、事件、样式、状态栏四个原生工具栏设置页；每个开关均连接实际行为。
- 面板主题和颜色、宽度、行高、字号可调整，默认宽 280 pt、行高 32 pt、字号比例 85%。
- 状态栏图标、公历、农历、星期、时间、自定义日期格式，可开关和拖拽排序。
- 图标默认以模板图像自动适配菜单栏明暗，也可固定为浅色或深色。
- 开机启动、悬停打开、面板固定、节日前一天通知。
- 通知中心/桌面 WidgetKit 月历，支持小、中、大尺寸、午夜时间线、独立农历和调休显示设置。
- 菜单栏面板及小组件分别保存深浅配色，每个颜色都可调整。

系统日历授权和通知默认由用户主动开启。应用不上传日程，也不包含统计 SDK。事件编辑、删除和复杂重复规则可从“打开系统日历”入口完成。

在桌面右键或通知中心选择“编辑小组件”，搜索 CalDock 添加月历。在“样式 → 通知中心小组件”调整其主题、配色、农历、星期起始和字体。点击小组件打开今天的菜单栏日历。系统控制 Widget 刷新时间，设置变动会同步共享容器并请求更新。

## 全屏

日历面板可在其他应用的全屏空间中显示，快捷键无需先退出全屏。已在文本编辑的真实全屏窗口中验证呼出。

如果系统自动隐藏整个菜单栏，图标只会在菜单栏显示时出现；`⌃⌘X` 始终是替代入口。刘海屏上若图标被过多菜单挤出，可以按住 `⌘` 拖动它，或只启用图标模块。应用不修改你的系统菜单栏设置。

## 低资源设计

- 默认一个对齐分钟的定时器，带 2 秒容差；只有显示秒或自定义格式包含秒时才启用每秒更新。
- 收起面板后释放 SwiftUI 视图，不执行月历刷新或日历轮询。
- 事件读取使用 EventKit 变更通知、250 ms 合并和可见 42 天范围，在独立队列执行；不启动自己的网络同步。
- 日期图标缓存；显示内容不变时跳过重绘，使用系统模板图像适配明暗，不监听绘制期间反复变化的外观属性。
- 节日提醒交给系统通知中心，不运行后台常驻任务。

查看 [实施与验收记录](docs/IMPLEMENTATION.md)。可复现空闲取样：先关闭设置和月历，再运行：

```sh
pgrep -x CalDock
python3 scripts/measure-idle.py <PID> --seconds 20 --output build/idle-metrics.json
footprint -p <PID> --sample 1 --noCategories
```

短时间 CPU 和内存取样不代表完整耗电测试，系统版本和日历数量也会影响结果。

## 开发与验证

```sh
swift test
bash scripts/build-app.sh debug
bash scripts/build-app.sh release
codesign --verify --deep --strict build/CalDock.app
```

`Package.swift` 可直接用 Xcode 打开。构建脚本自动打包资源、生成矢量绘制的图标并签名。设置 `CALDOCK_SIGN_IDENTITY` 可选择本机签名身份。

应用内验收（先退出其他 CalDock 实例）：

```sh
CALDOCK_TEST_MODE=1 /Applications/CalDock.app/Contents/MacOS/CalDock --verify-settings "$PWD/build/verification-settings.json"
open -W /Applications/CalDock.app --args --verify-system "$PWD/build/verification-system.json"
```

设置验收使用独立偏好域，不更改日常显示设置。系统验收需要已允许日历和通知，在临时日历中创建事件并清理，并测试登录项注册/注销后恢复原状态。系统验收必须通过 LaunchServices 正常启动；直接从命令行执行会改变 TCC 的负责进程归属，不能代表日常应用的授权。

需要公证时，在本机保存 notarytool 钥匙串凭据后运行：

```sh
CALDOCK_SIGN_IDENTITY='Developer ID Application: Your Company (TEAMID)' \
CALDOCK_NOTARY_PROFILE='your-keychain-profile' bash scripts/release.sh
```

发布脚本只在 Apple 返回 Accepted 后装订和重新打包，不会把仅完成签名的应用标为已公证。

## GitHub Actions 打包

[macOS build](https://github.com/yuhuotech/CalDock/actions/workflows/macos.yml) 仅在推送 `v*` 版本标签时打包：先测试，再构建 Universal 应用、Developer ID 签名、Apple 公证和装订，最后从解压后的 ZIP 和只读挂载的 DMG 复核签名和票据。`main` 推送和 PR 只测试，不读取签名材料。成功后在该次运行的 Artifacts 下载 `CalDock-universal-<版本>`，其中包含同名 ZIP、DMG 及各自的 `.sha256`；Universal 同时支持 Apple Silicon / arm64 和 Intel / x86_64。

发布新版本时，先同步修改 `Resources/Info.plist` 和 `Resources/Widget-Info.plist` 的 `CFBundleShortVersionString`，并递增两者的 `CFBundleVersion`，完整提交并推送后创建对应标签。例如当前 `0.1.1`：

```sh
git push origin main
git tag -a v0.1.1 -m "CalDock 0.1.1"
git push origin v0.1.1
```

工作流校验标签、主程序和 Widget 的版本一致后才读取密钥。当前文件名为 `CalDock-universal-0.1.1.zip` 和 `CalDock-universal-0.1.1.dmg`，分别附 `.sha256` 校验文件。DMG 内含可拖入 `/Applications` 的应用和快捷方式；应用和 DMG 均装订票据，DMG 自身也经过签名、公证。本机运行发布脚本也使用相同命名，可用 `python3 scripts/verify-release.py` 复核两种产物。

仅更新打包方式时，可使用带构建元数据的标签，例如 `v0.1.0+packaging.1`，应用版本及文件名仍为 `0.1.0`，保留原有发布标签。版本校验只允许基础版本匹配的标签及合法构建元数据。

仓库 Settings → Secrets and variables → Actions 需要以下配置：

| 类型 | 名称 | 来源 |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application 的 `.p12` 文件 Base64，包含私钥 |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时的密码 |
| Secret | `APPLE_ID` | Apple 开发者账号邮箱 |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | 此账号生成的 App 专用密码 |
| Variable | `APPLE_TEAM_ID` | `3BH46GJY6D` |
| Variable | `MACOS_SIGN_IDENTITY` | `Developer ID Application: Shanghai YuHuo Information Technology Co., Ltd. (3BH46GJY6D)` |

每次任务创建临时钥匙串，结束时清理；上传仅限发布包和公证报告，原始证书及密码不进入代码或 Artifact。当前证书有效期至北京时间 2027-02-02 06:12:15，续期后替换证书及密码 Secrets；若名称和团队不变，无需修改 Variables。App 专用密码撤销后也需要更新 Secret。

签名和公证用于通过 Gatekeeper 的开发者身份及恶意软件检查，不会取消 macOS 正常的首次下载打开确认、日历和通知授权。不要依靠移除隔离属性或关闭 Gatekeeper 分发应用。

日历日期测试覆盖截图中的 2026-10-16 / 九月初七、月边界、农历闰月、春节除夕、节气、官方调休、夏令时，以及事件结束于午夜时不落入下一天的边界。

## 数据说明

2026 年调休数据来源：[国务院办公厅关于2026年部分节假日安排的通知](https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html)，存放在 `Sources/CalendarCore/Resources/holidays.json`，后续年份需按正式公布的通知补充。节气使用太阳视黄经计算日期，不提供精确交节时刻。日历展示支持 1901–2099 年，使用本机时区。

已完成真实日历读写/筛选/清理、通知送达/取消、登录项注册/注销以及共享设置的本机验收。多屏坐标覆盖负坐标和小屏边界测试；实际 Intel 硬件与其他 macOS 版本需要对应设备，不能将 Universal 编译成功当作这些硬件的实测结果。公证记录见 `docs/verification/notarization-log.json`。
