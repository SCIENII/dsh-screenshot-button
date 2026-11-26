# dsh-screenshot-button

给 DSH（DeepSeek 的桌面客户端 / Cordis 插件宿主）的输入框加一个**截图按钮**，就在语音输入键左边：点一下开始框选屏幕区域，松手即出图，图片直接进剪贴板，回输入框 `Ctrl+V` 就能当附件发出去。

> 截图不是浏览器 API 抓的，而是由 DSH 的 **Host 进程**调 Windows 自带截图工具完成 —— 原因见下面「为什么要绕这么远」。

## 功能

| 操作 | 行为 |
| --- | --- |
| 左键点击剪刀键 | 区域截图：拉起 **Windows 自带截图工具**的覆盖层（等同 `Win+Shift+S`），拖完选区自动回传 |
| 右键点击剪刀键 | 整屏截图（虚拟桌面，多显示器一起，不弹任何界面） |
| `/snip` | 命令版区域截图（按钮失效时可直接用） |
| `/snip full` | 命令版整屏截图 |
| `/snip overlay` | 改用插件自绘覆盖层（系统截图工具被策略禁用时的兜底） |
| 覆盖层里 `Esc` / 鼠标右键 | 取消 |

截图同时落盘到 `%TEMP%\dsh-snips\snip-<时间戳>.png`，并以**两种格式**一起写入剪贴板：

- `Bitmap`（经典图片粘贴）
- `FileDrop`（同一个 PNG 文件）—— DSH 输入框的粘贴路由只认 `clipboardData` 里的**文件项**，光有位图时可能贴不进去。两种格式都在，Ctrl+V 无论走哪条路都能落地。

## 为什么要绕这么远

DSH 桌面版是 Electron 壳，主进程对渲染进程做了硬限制（`app.asar/lib/main.js` 的 `configureSession`）：

| 限制 | 后果 |
| --- | --- |
| `setDisplayMediaRequestHandler((_request, callback) => { callback({}) })` | `getDisplayMedia()` 永远拿不到画面 |
| `setPermissionRequestHandler((_c, _p, callback) => { callback(false) })` | 剪贴板等权限一律被拒 |
| `webRequest.onBeforeRequest` 只放行 `about:` / `data:` / `blob:` | 渲染进程里跳 `ms-screenclip:` 被 cancel，拉不起系统截图工具 |
| `setWindowOpenHandler(() => ({ action: 'deny' }))` | 也没有开新窗口兜底 |

所以渲染进程里**没有任何一条**可行的截图路径。本插件改成：客户端按钮只负责发一条 `/snip` 命令，真正的截图在 Host 进程里用 `execFile` 调 `powershell.exe -STA` 跑 `snip.ps1`。

注意第三条限制只对渲染进程生效 —— Host 进程用 `Start-Process 'ms-screenclip:'` 走的是 ShellExecute，会正常激活 AppX 协议，把系统截图工具的覆盖层拉起来。这就是本插件默认的截图引擎。

## 两个引擎

| 引擎 | 说明 | 稳定性 |
| --- | --- | --- |
| `native`（默认） | `Start-Process 'ms-screenclip:'` 拉起 Windows 自带截图工具；插件只负责「等剪贴板序号变化 → 取图 → 落盘 + 双格式写回」 | 覆盖层是系统自己的，不存在抢焦点、抢激活、DPI 错位、消息泵假死这些自绘窗口的老问题 |
| `overlay` | 插件自绘全屏 WinForms 覆盖层 + 橡皮筋选区（v1 的做法，保留作兜底） | 依赖 PowerShell 窗体拿到焦点，多显示器 / 高 DPI / 全屏应用场景下容易失灵 |

取消检测：系统截图工具的进程消失且剪贴板序号没变，就是用户按了 `Esc` —— 立刻返回取消，不用等超时（默认 120 秒）。

## 环境要求

- Windows（`snip.ps1` 依赖 WinForms / `System.Drawing`；`native` 引擎需要 `ms-screenclip:` 协议，Win10 1809+ 自带）
- DSH 桌面版或支持 Cordis bundle 的 DSH 宿主
- 无需额外依赖，用系统自带 Windows PowerShell 5.1

## 安装

把仓库克隆到任意目录，**路径里别带会被挪走的临时位置**（本项目就踩过一次：项目目录从桌面挪走后 profile 里的 `link:` 变成悬空链接，插件整体失效、按钮消失，看起来像"不稳定"）。然后在 DSH 里把这个目录装成插件（插件管理 → 安装本地 bundle，指向该目录）：

```powershell
git clone https://github.com/<you>/dsh-screenshot-button.git
```

安装后 profile 里会出现一条指向该目录的 link 依赖，例如：

```json
{
  "dependencies": { "@local/screenshot-button": "link:F:/path/to/dsh-screenshot-button" },
  "dsh": { "profile": { "bundles": ["@local/screenshot-button"] } }
}
```

包名 `@local/screenshot-button` 是本机安装时用的名字，克隆后可以自行改成自己的作用域，同步改一下 profile 里的依赖键即可。

## 用法

点剪刀键（左键区域 / 右键整屏）→ 拖选区 → 松手 → 输入框 `Ctrl+V`（图片也会以 PNG 文件形式在剪贴板里，可以直接粘贴或拖入）。

按钮在 `conversation.input.right` 槽（`order: 50`），也就是语音输入键的左侧。如果按钮没出现，先确认 profile 里的 `link:` 路径真实存在，再刷新窗口（`Ctrl+R`）。

## 项目结构

```
dsh-screenshot-button/
├── package.json        # 插件清单：dsh.bundle.patch + dsh.client
├── cordis.patch.yml    # bundle patch，把插件插进 profile
├── index.js            # Host 侧：注册 /snip 命令，execFile 调 PowerShell
├── client.js           # 客户端：注册到 conversation.input.right 的剪刀按钮
├── snip.ps1            # 截图器：native 引擎（系统截图工具）/ overlay 引擎（自绘）
├── icon.svg            # 插件图标
├── locale/{zh,en}.json # 插件元信息
└── docs/DETAIL.md      # 实现细节与踩坑记录
```

## 排错

细节写在 [docs/DETAIL.md](docs/DETAIL.md)，最常踩的三个：

1. **profile 的 `link:` 悬空**（目录被移动/改名）→ 插件静默不加载、按钮消失。改 `link:` 指向新路径，或重装一次 bundle。
2. **`DoubleBuffered` 是 protected 属性**，`$form.DoubleBuffered = $true` 会抛 `PropertyAssignmentException`，必须用反射设置（只有 `overlay` 引擎涉及）。
3. **`snip.ps1` 必须带 UTF-8 BOM**：Windows PowerShell 5.1 对无 BOM 文件按 ANSI/CP936 解码，脚本里的中文会被错切，报出 `Unexpected token '}'` 这类假语法错误。

离线自测（不点界面也能验证整条链路）：

```powershell
# native 引擎全链路：拉系统截图工具 → 合成拖拽 → 等剪贴板 → 落盘 → 双格式写回
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Engine native -Probe

# overlay 引擎全链路：真的弹出覆盖层，定时器模拟一次拖拽再自动接受
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Engine overlay -Probe

# 固定矩形裁切（不开任何界面）
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Engine overlay -Test -NoClipboard

# 整屏
powershell -NoProfile -STA -File snip.ps1 -Out "$env:TEMP\t.png" -Mode full -NoClipboard
```

## License

[MIT](LICENSE)
