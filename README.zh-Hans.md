# 岗哨 Watchpost

[tesla-sentry-f50](https://github.com/baicyber/tesla-sentry-f50) 的原生 iPhone 客户端。tesla-sentry-f50 是自己部署的特斯拉哨兵与行车记录仪查看器。岗哨只连你自己运行的服务器：填入服务器地址和管理员密码，就能查看事件、带驾驶遥测回放，并导出带水印的片段去分享。

English: [README.md](README.md).

## 能做什么

- **连接**自己的服务器，`http://` 或 `https://` 都可以，带端口。地址保存在本机，可以在几台服务器之间切换。
- **事件**按天分组，可按分类、日期和原因筛选，并显示服务器的存储概况。
- **回放**每一段一分钟的片段，可切换镜头：前视、后视、左B柱、右B柱、左前翼、右前翼，事件里录了哪几路就显示哪几路（只有四路的车显示四路）。播放暂停、前后跳十秒、带触发标记的进度条、全屏。车速、挡位、刹车、油门、方向盘角度和转向灯跟着进度走。录像里没有的值显示为“—”，不填假零。
- **导出并分享**：单分钟、单路画面，带服务器烧进去的水印，清晰度由你选。做好的文件通过系统分享面板发出去。
- **演示模式**：样例画面全部由代码生成。屏幕上一直有“演示数据”标识，样例事件不会被当成真实事件。

## 镜头名称

岗哨按镜头的实际安装位置命名：`*_pillar` 文件是 B 柱镜头，`*_repeater` 文件是前翼镜头。上游网页查看器（v2.8.45）这两类的显示正好相反。岗哨不改动服务器，只是按位置标注拿到的文件。

## 环境要求

- 一台自己的 tesla-sentry-f50 服务器，以及它的地址和管理员密码。
- 编译需要 Xcode 26 或更新版本（实际用 Xcode 27.1 构建和测试）。App 运行在 iOS 18.0 或更高版本的 iPhone 上。

## 运行

打开 `WatchpostApp.xcodeproj`，选 `WatchpostApp` scheme 和一台 iPhone 模拟器，按 ⌘R。没有服务器时，在连接页点**体验演示**先看看。

命令行方式（模拟器已启动）：

```sh
xcodebuild -project WatchpostApp.xcodeproj -scheme WatchpostApp -sdk iphonesimulator build &&
xcrun simctl install booted build/Debug-iphonesimulator/WatchpostApp.app &&
xcrun simctl launch booted com.jakezai.watchpost-pwvw
```

单元测试在测试进程里自带一个回环服务器，不需要 tesla-sentry-f50 服务器：

```sh
xcodebuild -project WatchpostApp.xcodeproj -scheme WatchpostApp -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## 隐私

- 不建账号，没有自己的云服务。App 只和你填写的地址通信，不含统计或广告 SDK。
- 服务器地址和密码只留在本机：密码在 iOS 钥匙串里，其余在 App 自己的偏好设置里。
- 允许明文 `http://`，因为家里的服务器在局域网里常常是这样访问的。访问局域网里的服务器时，iOS 会询问是否允许“本地网络”权限。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `WatchpostApp/Data` | 模型、服务器回复的解析、服务器会话、导出与回放逻辑 |
| `WatchpostApp/Views` | 三个界面：连接、事件、回放 |
| `WatchpostApp/DemoAssets` | 演示模式用的样例画面、缩略图和遥测 |
| `WatchpostAppTests` | 单元测试，含一个按真实服务器方式应答的回环服务器 |
| `Tools` | 文案、演示素材生成器、本机服务器小工具。见 [Tools/README.md](Tools/README.md) |

界面文字在代码里写英文，简体中文在 `Tools/Strings/*.json` 里。改了任何界面文字后，运行 `python3 Tools/Strings/merge.py` 重新生成目录并检查 key。

## 许可

MIT，见 [LICENSE](LICENSE)。tesla-sentry-f50 是 baicyber 的独立项目，同样是 MIT。

岗哨是个人爱好项目，与 Tesla, Inc. 没有关联。“Tesla”和“Tesla Sentry”是 Tesla, Inc. 的商标。
