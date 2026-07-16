# MusicSign — 把当前播放的歌投到飞书签名

macOS 菜单栏小软件:读取系统正在播放的歌,自动投射到飞书"个性签名"。

## 功能

- **取歌**:系统级 Now Playing(MediaRemote 经 Apple 签名的 `/usr/bin/perl` 加载 dylib 调用),覆盖**所有**播放器(Spotify / Apple Music / QQ音乐 / 网易云 / 酷狗 / 汽水音乐 / Chrome …),无需对每个 app 单独适配。
- **飞书签名**:登录网页版飞书抓 cookie,直接调飞书接口改签名。
- **前后缀**:可自定义签名首尾(如前缀 `🎧`、后缀 `(now)`)。
- **暂停恢复**:暂停时自动切到"暂停签名"(可留空=清空),播放时切回歌名。

## 系统要求

- macOS 14.0(Sonoma)及以上
- Universal:Apple Silicon(arm64)与 Intel(x86_64)均可

## 安装(下载 Release 版)

1. 从 [Releases](https://github.com/dubaiii/feishu-music-sign/releases) 下载 `MusicSign-x.x.x.zip`,解压得到 `MusicSign.app`。
2. 拖到 `/Applications`(或任意位置)。
3. 本 app 未签名未公证, 提示安装不了 → 系统设置 → 隐私与安全性, 往下滑动到「安全性」板块，会看到一行提示：已阻止使用 “MusicSign”, 点击右侧 仍要打开，输入电脑开机密码确认，就能正常启动软件，后续不会再拦截。
4. 双击启动 → 菜单栏出现 ♪ 图标。

## 使用

1. 点菜单栏 ♪ → **登录飞书** → 弹窗里登录网页版飞书 → 关窗自动存 cookie。
2. 勾 **同步到飞书签名**。
3. (可选)填前缀 / 后缀 / 暂停签名。预览行实时显示最终签名。
4. 之后每换一首歌,飞书签名自动变成 `<前缀> 标题 - 艺人 <后缀>`;暂停时变成暂停签名。

> Cookie 过期(飞书返回 4xx)时 App 会自动清缓存并提示重新登录。

## 文件

- `app/MusicSignApp.swift` — App 主体(NowPlaying / Feishu 登录+cookie 直调 / 菜单栏 UI)。
- `app/build.sh`、`app/release.sh` — 本机构建 / universal 打包。
- `bin/mr_adapter.m` → `libmr_adapter.dylib` — MediaRemote 适配器(经 perl 加载)。
- `bin/loader.pl` — DynaLoader 加载 dylib 的胶水。
- `~/Library/Application Support/MusicSign/feishu_cookies.json` — 飞书登录态(运行时)。

## 说明与限制

- 飞书签名写入走 web `passport/users/details` 接口(官方无签名写 API)。如飞书改版导致失效,可能需调整。
- macOS 15.4+/26 上,Apple 限制了普通 app 直接加载 MediaRemote.framework;本 App 借助系统自带的 Apple 签名 `/usr/bin/perl` 加载 dylib 绕过,实测在 macOS 26.3 可用。
