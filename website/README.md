# CalDock 官网

部署地址：`https://caldock.yuhuotech.com`。这是一个无需构建的静态单页，HTML、CSS、JavaScript 和图片均在本目录；不依赖 Node.js、CDN 字体或前端框架。

## 本地预览

从仓库根目录运行：

```sh
python3 -m http.server 8787 --bind 127.0.0.1 --directory website
```

打开 `http://127.0.0.1:8787`。只预览网页，不会安装或启动 CalDock。

## 部署

1. 将本目录中的 `index.html`、`styles.css`、`app.js`、`robots.txt`、`sitemap.xml` 和整个 `assets/` 上传到网站根目录。
2. 为 `caldock.yuhuotech.com` 配置 DNS 和 HTTPS，让根路径返回 `index.html`。
3. 检查图片、明暗切换、下载入口和手机布局。

使用 Nginx、Caddy、对象存储静态托管或其他静态服务器均可，不需要服务端进程。Canonical、Open Graph 和 sitemap 已使用正式域名。HTML 和 JS 建议保留较短缓存时间，方便后续修改。

下载入口默认指向 GitHub 最新 Release；页面仅发送一次公开 GitHub API 请求，将链接更新到最新版本的 DMG / ZIP。API 超时、受限或关闭 JavaScript 时，仍可通过 Release 页面下载，不会跳到已失效的固定版本文件。不包含分析脚本、Cookie 或账号功能。

## 素材

- `app-icon.png`：项目现有应用图标。
- `calendar-light.png` / `calendar-dark.png`：由当前生产代码中的 `CalendarView` 离屏导出，使用内存偏好和示例月份，不读取个人日程，不创建应用实例。
- `about.png`：关于与软件更新页的实际设置截图。

更新截图时保留真实界面与来源。月历导出入口为 `scripts/render-website-previews.swift`；它与 `Sources/CalDock/CalendarView.swift`、`CalendarModel.swift` 和 CalendarCore 一起编译，输出 PNG 后退出。网站源码和本项目自有素材采用根目录的 MIT 许可。
