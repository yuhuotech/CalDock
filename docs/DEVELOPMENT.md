# 开发与发布

CalDock 使用 Swift、AppKit、SwiftUI、EventKit 和 WidgetKit；更新采用 Sparkle 2.10.0。要求 macOS 14+，建议使用与 CI 一致的 Xcode 16.4 或更新版本。依赖版本固定在 `Package.resolved`。

## 本地构建

```sh
git clone https://github.com/yuhuotech/CalDock.git
cd CalDock
swift test
bash scripts/build-app.sh debug
open build/CalDock.app
```

脚本构建包含 arm64、x86_64 的 Universal 主程序和 Widget，复制资源及 Sparkle，按嵌套顺序签名，并验证扩展入口、资源和签名。Bundle ID 为 `com.yuhuo.caldock`，Widget 为 `com.yuhuo.caldock.widget`。

构建脚本默认查找当前项目团队的 Developer ID；其他开发者可指定自己的身份：

```sh
CALDOCK_SIGN_IDENTITY='Developer ID Application: Your Company (TEAMID)' \
bash scripts/build-app.sh release
```

纯界面开发可使用 `CALDOCK_SIGN_IDENTITY=-`。临时签名不保证日历授权、App Group 或跨版本更新可用，不能用作正式分发。使用其他团队时，也需要同步修改两份 entitlements 中的 App Group 和 CalendarCore 中的共享容器配置。

安装脚本会备份已有应用到忽略的构建目录；验证时只运行一个实例，避免重复菜单栏图标：

```sh
bash scripts/install-app.sh
open /Applications/CalDock.app
```

## 验证

```sh
swift test
codesign --verify --deep --strict build/CalDock.app
CALDOCK_TEST_MODE=1 build/CalDock.app/Contents/MacOS/CalDock \
  --verify-settings "$PWD/build/verification-settings.json"
open -W /Applications/CalDock.app --args \
  --verify-system "$PWD/build/verification-system.json"
```

设置验收使用独立显示偏好域，更新开关验证后恢复原值。系统验收需要用户已授予日历和通知权限，会创建并清理临时日历/事件、测试通知及登录项后恢复状态。请在专门的本机测试会话中运行，不在托管 CI 执行。必须经 LaunchServices 启动系统验收，直接执行二进制的 TCC 归属不同。

空闲取样：关闭月历与设置，使用 `scripts/measure-idle.py <PID> --seconds 60`。不同系统、日历数量和显示设置会影响结果；短时间取样不等于完整耗电测试。

已归档的验证见 [实施记录](IMPLEMENTATION.md) 和 [验收数据](verification/)。Universal 构建成功不等于已在所有 Intel 设备或 macOS 版本上实测。

## 签名、公证与更新源

先安装带私钥的 Developer ID Application 证书，并用 `xcrun notarytool store-credentials` 保存 Apple 公证凭据，再执行：

```sh
CALDOCK_SIGN_IDENTITY='Developer ID Application: Your Company (TEAMID)' \
CALDOCK_NOTARY_PROFILE='your-keychain-profile' \
CALDOCK_SPARKLE_KEY_FILE='/path/to/private-update-key' \
bash scripts/release.sh
python3 scripts/verify-release.py
```

仅在 Apple 返回 `Accepted` 后装订并验证票据，生成 ZIP、含 Applications 快捷方式的 DMG 和各自的 SHA256，再生成签名的 `appcast.xml`。Apple 签名、装订及网络校验会有限次重试，最终失败仍阻止发布。不会通过关闭 Gatekeeper 或移除隔离属性绕过验证。

Sparkle 的 Ed25519 私钥与 Apple 签名证书是两种不同材料。公钥在 `Resources/Info.plist`；私钥必须安全保管并跨版本保持一致，不能随意重新生成。更新源与 ZIP 在客户端验证签名，ZIP 在解压前验证。自动检查间隔为 3600 秒，用户确认后才下载和安装，不启用静默安装或系统画像。

## GitHub Actions

[macOS build](https://github.com/yuhuotech/CalDock/actions/workflows/macos.yml) 在 `main` 推送和 PR 时只测试，仅推送 `v*` 标签时打包、校验并发布 GitHub Release。发布任务单独具有 `contents:write` 权限，签名任务保持只读。

在仓库 Settings → Secrets and variables → Actions 配置：

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | 含私钥的 Developer ID Application `.p12` 的 Base64 |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | `.p12` 导出密码 |
| Secret | `APPLE_ID` | 公证账号邮箱 |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | 对应账号的 App 专用密码 |
| Secret | `SPARKLE_ED_PRIVATE_KEY` | Base64 Ed25519 更新私钥种子 |
| Variable | `APPLE_TEAM_ID` | Apple Developer 团队 ID |
| Variable | `MACOS_SIGN_IDENTITY` | Developer ID Application 的完整身份名称 |

任务创建临时钥匙串和签名文件，结束时清理；Artifact 仅包含公开安装包、更新源及公证报告。证书过期或凭据撤销时更新对应 Secret。不要向仓库或日志写入密钥。

发布时同步更新两份 Info.plist 的 `CFBundleShortVersionString`，递增两者的 `CFBundleVersion`。标签必须匹配应用版本：

```sh
git push origin main
git tag -a vX.Y.Z -m "CalDock X.Y.Z"
git push origin vX.Y.Z
```

产物命名为 `CalDock-universal-X.Y.Z.zip`、`CalDock-universal-X.Y.Z.dmg` 及各自的 `.sha256`。`appcast.xml` 与安装包同次上传后才公开 Release，客户端从 `releases/latest/download/appcast.xml` 检查更新。仅重做打包时也支持版本相同的合法构建元数据标签，例如 `v0.1.3+packaging.1`，不要覆盖已经发布的标签。

## 官网

`website/` 为无需构建的静态官网，部署说明见 [website/README.md](../website/README.md)。官网使用本项目真实 SwiftUI 月历视图导出的展示图片及设置页截图，不包含个人日程。离屏月历导出工具为 `scripts/render-website-previews.swift`，不创建菜单栏实例或写入偏好。
