# BookmarkSync 简体中文支持

[English](README.md) · 简体中文

macOS 菜单栏书签同步应用，支持原生英文／简体中文本地化。
中文本地化由 [JasonZhang1225](https://github.com/JasonZhang1225) 贡献。

## 汉化范围

- 菜单栏、按钮提示、首次使用指南和窗口标题。
- 统一书签窗口、搜索结果数量、元数据和各浏览器同步状态。
- 同步活动中的新增／更新／删除提示，以及默认同步组的显示名称。
- 备份管理、恢复结果与写入错误提示。

默认跟随系统语言。要单独切换：打开 **系统设置 → 通用 → 语言与地区 →
应用程序**，添加 BookmarkSync，选择简体中文或英语，然后完全退出并重新打开应用。

## 同步行为

BookmarkSync 监测 Mac 上的浏览器书签文件，再通过浏览器原有的账号同步传播到其他设备。
**目标浏览器运行时，写入会等待；需要完全退出该浏览器（⌘Q），仅关闭窗口不够。**
写入完成后，重新打开浏览器，使其加载书签并进行原生云同步。

汉化不修改同步算法、书签名称、浏览器配置名称或磁盘中的标识。
`Deleted by BookmarkSync` 是同步程序识别的删除归档文件夹，仍保留英文名称；
数据库中的 `Set N` 和活动前缀也保持原格式，仅在界面显示时翻译。

## 构建与验证

需要 macOS 14 或更新版本、Xcode 和 XcodeGen：

```sh
brew install xcodegen
xcodegen generate
open BookmarkSync.xcodeproj
```

在 Xcode 中选择 BookmarkSync scheme 后构建／运行。开发者签名配置沿用上游；
如果需要签名安装，请在本地选择自己的开发团队。

不依赖 Xcode 的资源检查：

```sh
python3 scripts/check_localizations.py
```

macOS 上运行完整测试（不需要签名）：

```sh
xcodebuild test -project BookmarkSync.xcodeproj -scheme BookmarkSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=
```

本地化资源位于 `BookmarkSync/Localization/en.lproj` 与 `zh-Hans.lproj`。
增加文案时请同时更新两种语言，保留格式占位符；动态文案通过 `L10n` 查找，
搜索数量通过 `Localizable.stringsdict` 处理复数。PR 会触发 macOS 构建和 XCTest 检查。

## 替换旧版后权限提示仍出现

旧 CI 下载包使用临时签名。替换应用后，macOS 可能不再认可旧应用的完全磁盘访问授权，
即使系统设置里的开关仍然打开。请先退出 BookmarkSync，在 **系统设置 → 隐私与安全性 →
完全磁盘访问权限** 中移除旧条目，再添加 `/Applications/BookmarkSync.app`，打开权限并重新启动应用。
菜单栏“浏览器配置”旁的刷新按钮可以重新扫描。

扫描结果不完整时，应用会保留已有配置、启用状态和书签，并暂停无法访问的配置。
Chrome、Edge 和 Firefox 的显示名称变化时，优先按书签文件路径识别原配置。
已经被旧版删除的应用内数据需要从备份恢复，或在浏览器配置重新启用后导入。

新的 CI 使用固定自签名证书，避免每次构建都改变签名身份。第一次从临时签名版切换时
仍需重新授权一次；后续使用同一证书签名的更新应保留授权，实际系统行为需安装替换验证。
证书备份、CI 校验和 Secrets 恢复说明见 [CI 固定签名](docs/ci-signing.md)。
