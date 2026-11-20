# dsh-screenshot-button

给 DSH（DeepSeek 的桌面客户端 / Cordis 插件宿主）的输入框加一个**截图按钮**，就在语音输入键左边：点一下开始框选屏幕区域，松手即出图，图片直接进剪贴板，回输入框 `Ctrl+V` 就能当附件发出去。

> 截图不是浏览器 API 抓的，而是由 DSH 的 **Host 进程**调 PowerShell 完成 —— 原因见下面「为什么要绕这么远」。

## 功能

| 操作 | 行为 |
| --- | --- |
| 左键点击剪刀键 | 区域截图：全屏覆盖层 + 橡皮筋选区，松手裁切完成 |
| 右键点击剪刀键 | 整屏截图（虚拟桌面，多显示器一起，实测双屏 3840×1080） |
| `/snip` | 命令版区域截图（按钮失效时可直接用） |
| `/snip full` | 命令版整屏截图 |
| 覆盖层里 `Esc` / 鼠标右键 | 取消 |
| 180 秒无操作 | 自动取消，不留僵死全屏窗口 |

截图同时落盘到 `%TEMP%\dsh-snips\snip-<时间戳>.png`，并写入剪贴板（成功时提示「截图已复制到剪贴板，回到输入框按 Ctrl+V 粘贴」）。

## 为什么要绕这么远

DSH 桌面版是 Electron 壳，主进程对渲染进程做了硬限制（`app.asar/lib/main.js` 的 `configureSession`）：

| 限制 | 后果 |
| --- | --- |
| `setDisplayMediaRequestHandler((_request, callback) => { callback({}) })` | `getDisplayMedia()` 永远拿不到画面 |
| `setPermissionRequestHandler((_c, _p, callback) => { callback(false) })` | 剪贴板等权限一律被拒 |
| `webRequest.onBeforeRequest` 只放行 `about:` / `data:` / `blob:` | `ms-screenclip:` 自定义协议被 cancel，拉不起系统截图工具 |
| `setWindowOpenHandler(() => ({ action: 'deny' }))` | 也没有开新窗口兜底 |

所以渲染进程里**没有任何一条**可行的截图路径。本插件改成：客户端按钮只负责发一条 `/snip` 命令，真正的截图在 Host 进程里用 `execFile` 调 `powershell.exe -STA` 跑 `snip.ps1`（WinForms 覆盖层 + `Graphics.CopyFromScreen` + 裁切 + 剪贴板写入）。

## 环境要求

- Windows（`snip.ps1` 依赖 WinForms / `System.Drawing`）
- DSH 桌面版或支持 Cordis bundle 的 DSH 宿主
- 无需额外依赖，用系统自带 Windows PowerShell 5.1

## 安装

把仓库克隆到任意目录，然后在 DSH 里把这个目录装成插件（插件管理 → 安装本地 bundle，指向该目录）：

```powershell
git clone https://github.com/<you>/dsh-screenshot-button.git
```

安装后 profile 里会出现一条指向该目录的 link 依赖，例如：

```json
{
  "dependencies": { "@local/screenshot-button": "link:C:/path/to/dsh-screenshot-button" },
  "dsh": { "profile": { "bundles": ["@local/screenshot-button"] } }
}
```

包名 `@local/screenshot-button` 是本机安装时用的名字，克隆后可以自行改成自己的作用域，同步改一下 profile 里的依赖键即可。

## 用法

点剪刀键（左键区域 / 右键整屏）→ 拖动选区 → 松手 → 输入框 `Ctrl+V`。

按钮在 `conversation.input.right` 槽（`order: 50`），也就是语音输入键的左侧。如果按钮没出现，刷新窗口（`Ctrl+R`）。

## 项目结构

```
dsh-screenshot-button/
├── package.json        # 插件清单：dsh.bundle.patch + dsh.client
├── cordis.patch.yml    # bundle patch，把插件插进 profile
├── index.js            # Host 侧：注册 /snip 命令，execFile 调 PowerShell
├── client.js           # 客户端：注册到 conversation.input.right 的剪刀按钮
├── snip.ps1            # 真正的截图器：覆盖层 + 选区 + 裁切 + 剪贴板
├── icon.svg            # 插件图标
├── locale/{zh,en}.json # 插件元信息
└── docs/DETAIL.md      # 实现细节与踩坑记录
```

## 排错

两个已经踩过的坑，细节写在 [docs/DETAIL.md](docs/DETAIL.md)：

1. **`DoubleBuffered` 是 protected 属性**，`$form.DoubleBuffered = $true` 会抛 `PropertyAssignmentException`，必须用反射设置。
2. **`snip.ps1` 必须带 UTF-8 BOM**：Windows PowerShell 5.1 对无 BOM 文件按 ANSI/CP936 解码，脚本里的中文注释会被错切，报出 `Unexpected token '}'` 这类假语法错误。

离线自测（不点界面也能验证整条链路）：

```powershell
# 固定矩形裁切，验证裁图逻辑
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Test -NoClipboard

# 真的弹出覆盖层，定时器模拟一次拖拽再自动接受
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Probe

# 整屏
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Full -NoClipboard
```

## License

[MIT](LICENSE)
