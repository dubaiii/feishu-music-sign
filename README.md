# MusicSign — 把当前播放的歌投到飞书签名

macOS 菜单栏小软件(类似 RunningCat):读取系统当前播放的歌曲,投射到飞书"个性签名"。
不依赖飞书官方 OpenAPI(官方无签名写接口),走 **capture-replay**:录下网页端改签名的那条请求,之后用 cookie + 配方把签名文本替换成歌名重放。

## 现状与限制(重要)

- **取歌**:
  - Spotify / Apple Music → AppleScript,稳定,需一次"自动化"权限。
  - **QQ音乐 / 网易云 / 酷狗** → 这几个 app 不暴露 AppleScript 字典;唯一能一次性覆盖它们的"系统级 Now Playing"接口(`MediaRemote` 私框架)在 **macOS 15.3+/26 被 Apple 锁死**(返回 `Operation not permitted`),第三方读不到。App 仍会以崩溃隔离的子进程试一次,失败即禁用。当前对这几个走**辅助功能读窗口标题**的兜底(需"辅助功能"权限),**best-effort**——取决于该 app 是否把"歌名 - 歌手"放进窗口标题。如读不到,可在 `axApps` / `axWindowTitle` 处按实际 UI 调整。
- **飞书签名写入**:capture-replay。需你登录网页版飞书并录制一次签名请求。

## 构建

```sh
cd /Users/cf.fu/Projects/feishu-music-sign/app
./build.sh            # 产出 ../build/MusicSign.app
open ../build/MusicSign.app
```

依赖:Xcode 命令行工具(`swiftc`/`clang`)。

## 一次性使用流程

1. **启动 App** → 菜单栏出现 `♪` / `🎵 歌名`。首次读 Spotify/Apple Music 会弹"自动化"权限框,允许。
2. **登录飞书**:点菜单 → "登录飞书" → 在弹出窗口登录网页版飞书 → 关窗即自动抓 cookie 存到
   `~/Library/Application Support/MusicSign/feishu_cookies.json`。
3. **录制签名请求**(关键):点 "录制签名请求(把签名改成 __SIG__)" → 在弹出的飞书窗口里把你的"个性签名"改成 `__SIG__` 并保存。
   App 会从抓到的请求里锁定含 `__SIG__` 的那条,存为配方 `feishu_recipe.json`(含 URL/方法/请求头/请求体)。
4. **开启同步**:勾 "同步到飞书签名"。之后每换一首歌,App 用 cookie + 配方把 `__SIG__` 替换成 `🎵 歌名 - 歌手` 重放,飞书签名即更新。

> 哨兵 `__SIG__` 的作用:自动定位"哪条请求是改签名的"以及"签名文本在请求体里的位置",不猜接口字段。Feishu 改版后重录一次即可。

## 权限清单

- 自动化(Apple Events):读 Spotify / Apple Music。
- 辅助功能(Accessibility):QQ/网易云/酷狗窗口标题兜底。
- 网络:登录飞书、重放签名请求。

## 开机自启

```sh
mkdir -p ~/Library/LaunchAgents
cp /Users/cf.fu/Projects/feishu-music-sign/com.fufu.musicsign.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.fufu.musicsign.plist
```

## 文件

- `app/MusicSignApp.swift` — App 主体(NowPlaying / Feishu 登录 / capture-replay / 菜单栏 UI)。
- `app/Info.plist`、`app/build.sh`。
- `bin/nowplaying` — shell 版取歌(Spotify/Apple Music,AppleScript)。
- `bin/nowplaying.m` / `bin/nowplaying-mr` — MediaRemote 私框架版(被锁的崩溃隔离子进程)。
- `~/Library/Application Support/MusicSign/feishu_cookies.json`、`feishu_recipe.json` — 运行时数据。
