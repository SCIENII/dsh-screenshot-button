# 截图按钮插件（DSH 桌面版）

在输入框工具行、语音输入键左侧加一个剪刀按钮：点一下即可框选屏幕区域，截好的图直接进剪贴板，回到输入框 `Ctrl+V` 就能作为图片附件发出。

## 为什么不由渲染进程截图

DSH 桌面版是 Electron 壳，`app.asar/lib/main.js` 对渲染进程做了硬限制：

| 位置 | 代码 | 后果 |
| --- | --- | --- |
| `configureSession` | `setDisplayMediaRequestHandler((_request, callback) => { callback({}); })` | `getDisplayMedia()` 永远拿不到画面，直接失败 |
| `configureSession` | `setPermissionRequestHandler((_c, _p, callback) => { callback(false); })` | 剪贴板写入等权限一律拒绝 |
| `configureSession` | `webRequest.onBeforeRequest` 仅放行 `about:` `data:` `blob:` | `ms-screenclip:` 自定义协议被 cancel，拉不起截图工具 |
| 窗口装配 | `setWindowOpenHandler(() => ({ action: 'deny' }))` | 也没有开新窗口兜底 |

所以截图改由 **Host（DSH 的 node 进程）** 执行：客户端按钮只负责发一条 `/snip` 命令。

## 组成

| 文件 | 角色 |
| --- | --- |
| `client.js` | 客户端按钮，注册到 `conversation.input.right` 槽；点击后调用 `ctx.remote.commands.execute(sessionId, '/snip')` |
| `index.js` | Host 插件，注册 `/snip` 命令，用 `child_process.execFile` 调 PowerShell 执行截图 |
| `snip.ps1` | 真正的截图器：全屏覆盖层 + 橡皮筋选区，裁切后写 PNG 并写入剪贴板 |
| `cordis.patch.yml` | bundle patch，把插件插进 profile |
| `locale/*.json` | 插件元信息（设置页展示） |

## 用法

- **左键**：区域截图（出现覆盖层 → 拖动选区 → 松手完成）
- **右键**：整屏截图（虚拟屏全屏，多显示器一起）
- 覆盖层里 `Esc` 或右键 = 取消；180 秒无操作自动取消
- 截图完成后剪贴板即是图片，回输入框 `Ctrl+V` 粘贴
- 也可以直接输入 `/snip` 或 `/snip full`

截图文件同时落到 `%TEMP%\dsh-snips\snip-<时间戳>.png`。

## 依赖与限制

- 仅 Windows（`snip.ps1` 用 WinForms + `System.Drawing`），走 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -STA`
- 高 DPI 已通过 `SetProcessDPIAware` 处理，选区坐标与位图坐标一致
- 剪贴板是全局副作用：截图会覆盖当前剪贴板内容
- `snip.ps1` 支持 `-Test`（用固定矩形代替鼠标拖拽，离线验证裁切逻辑）、`-Probe`（真的把覆盖层显示出来，用定时器模拟一次拖拽再自动接受，验证 Form/Paint/裁切全链路）、`-NoClipboard`（只落盘不进剪贴板）

## 两个已踩过的坑

1. **`DoubleBuffered` 是 protected 属性。** `$form.DoubleBuffered = $true` 在 PowerShell 里会抛 `PropertyAssignmentException`，必须用反射设置：
   ```powershell
   $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
     [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
   $dbProp.SetValue($form, $true, $null)
   ```
2. **`snip.ps1` 必须带 UTF-8 BOM。** Windows PowerShell 5.1 对无 BOM 文件按 ANSI/CP936 解码，脚本里的中文注释和提示文字会被错切，导致 `Unexpected token '}'` 这类假语法错误（脚本其实没问题）。改完脚本要确认头三字节是 `239,187,191`：
   ```powershell
   $c = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
   [System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))
   ```


## 改动后如何生效

- Host 侧（`index.js` / `snip.ps1`）：在设置 → 插件里把本插件关闭再打开，或重启 DSH
- 客户端侧（`client.js`）：刷新窗口（`Ctrl+R`）
