# 截图按钮插件（DSH 桌面版）

在输入框工具行、语音输入键左侧加一个剪刀按钮：点一下即可框选屏幕区域，截好的图进剪贴板，回到输入框 `Ctrl+V` 就能作为图片附件发出。

## 为什么不由渲染进程截图

DSH 桌面版是 Electron 壳，`app.asar/lib/main.js` 对渲染进程做了硬限制：

| 位置 | 代码 | 后果 |
| --- | --- | --- |
| `configureSession` | `setDisplayMediaRequestHandler((_request, callback) => { callback({}); })` | `getDisplayMedia()` 永远拿不到画面，直接失败 |
| `configureSession` | `setPermissionRequestHandler((_c, _p, callback) => { callback(false); })` | 剪贴板写入等权限一律拒绝 |
| `configureSession` | `webRequest.onBeforeRequest` 仅放行 `about:` `data:` `blob:` | 渲染进程里跳 `ms-screenclip:` 被 cancel |
| 窗口装配 | `setWindowOpenHandler(() => ({ action: 'deny' }))` | 也没有开新窗口兜底 |

关键区别：`webRequest` 那条限制只作用于**渲染进程的请求**。Host 进程用 `Start-Process 'ms-screenclip:'` 走 ShellExecute → AppX 协议激活，系统截图工具照常被拉起。所以截图改由 **Host（DSH 的 node 进程）** 执行：客户端按钮只负责发一条 `/snip` 命令。

实测（Host 侧）：`Start-Process 'ms-screenclip:'` 会拉起 `SnippingTool` 进程（窗口标题「截图工具覆盖」），合成拖拽后剪贴板序号从 28 跳到 39，剪贴板出现位图 —— 整条链路 4 秒内跑完。

## 引擎

### native（默认）

1. 记录 `GetClipboardSequenceNumber()`
2. `Start-Process 'ms-screenclip:'` 拉起系统截图工具覆盖层
3. 每 120ms 轮询剪贴板序号；序号变化后等 260ms 让截图工具写完，再 `Clipboard::GetImage()`
4. 截图工具进程消失且序号没变 → 用户按了 `Esc`，立即返回 `CANCEL`
5. 落盘 PNG，并把**同一张图以 `Bitmap` + `FileDrop` 两种格式**写回剪贴板

为什么不自己画覆盖层：自绘全屏窗要靠 `TopMost` + `Activate()` 抢焦点，多显示器、高 DPI、全屏应用、Electron 自己的置顶窗口都会干扰它；而且 WinForms 消息泵里任何一个 Paint/事件异常都会让覆盖层假死。系统截图工具的覆盖层没有这些问题。

### overlay（兜底）

v1 的做法，保留给「系统截图工具被组策略/精简系统砍掉」的场合：PowerShell 起一个无边框 `TopMost` 全屏 Form，`Add_Paint` 画暗幕 + 橡皮筋，`Graphics.CopyFromScreen` 抓虚拟屏，按选区 `Clone` 裁切。`-Engine overlay` 或 `/snip overlay` 强制使用。

## 组成

| 文件 | 角色 |
| --- | --- |
| `client.js` | 客户端按钮，注册到 `conversation.input.right` 槽；点击后调用 `ctx.remote.commands.execute(sessionId, '/snip')` |
| `index.js` | Host 插件，注册 `/snip` 命令，用 `child_process.execFile` 调 PowerShell 执行截图 |
| `snip.ps1` | 真正的截图器：native / overlay 两个引擎 + 裁切 + 双格式剪贴板写入 |
| `cordis.patch.yml` | bundle patch，把插件插进 profile |
| `locale/*.json` | 插件元信息（设置页展示） |

## 用法

- **左键**：区域截图（系统截图工具覆盖层）
- **右键**：整屏截图（虚拟屏全屏，多显示器一起，不弹界面）
- 取消：`Esc`（立即识别，不等超时）、右键取消（overlay 引擎）
- 截图完成后剪贴板里同时有位图和 PNG 文件，回输入框 `Ctrl+V` 粘贴
- 也可以直接输入 `/snip`、`/snip full`、`/snip overlay`

截图文件同时落到 `%TEMP%\dsh-snips\snip-<时间戳>.png`。

## 为什么剪贴板要写两种格式

DSH 输入框的粘贴有两条路：

1. 编辑器内部的 paste（`ComposerContentEditable`）—— 处理位图
2. 文档级粘贴路由（`dsh-client-ui-conversation/src/client/input/file-intake.ts`）—— 只处理 `clipboardData.items` 里 `kind === 'file'` 的项，遇到可编辑控件之外的粘贴才接管

系统截图工具默认只放 `Bitmap`，某些情况下（焦点在编辑器外、或位图没有被合成为文件项）第二条路拿不到东西，表现就是「按了 Ctrl+V 没反应」。所以插件在落盘后把同一个 PNG 以 `Bitmap` + `FileDrop` 一起塞回剪贴板，两条路都能命中。

## 依赖与限制

- 仅 Windows（`snip.ps1` 用 WinForms + `System.Drawing`），走 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -STA`
- `native` 引擎需要 `ms-screenclip:` 协议（Win10 1809+ 的「截图和草图」/ Win11「截图工具」自带）
- 高 DPI 由 `SetProcessDPIAware` 处理；`native` 引擎的坐标与 DPI 完全交给系统，不存在换算误差
- 剪贴板是全局副作用：截图会覆盖当前剪贴板内容
- 自测开关：`-Test`（overlay 固定矩形，不开界面）、`-Probe`（真开界面 + 合成拖拽）、`-NoClipboard`（只落盘）、`-Engine native|overlay|auto`、`-Mode region|full`、`-TimeoutSec`

## 踩过的坑

1. **profile 的 `link:` 悬空 = 插件静默死亡。** 项目目录从 `C:\Users\SCIEN\Desktop\工作台` 挪到 `F:\DesktopVault\01-项目\工作台` 后，profile 里 `link:C:/Users/SCIEN/Desktop/工作台/dsh-screenshot-button` 仍指旧路径，pnpm 的 junction 悬空，Host 模块加载不到、按钮消失 —— 表面症状就是"插件不稳定"。修法：`plugin_manager remove_bundle` → `install_bundle` 指向新路径。
2. **`DoubleBuffered` 是 protected 属性。** `$form.DoubleBuffered = $true` 在 PowerShell 里会抛 `PropertyAssignmentException`，必须用反射设置：
   ```powershell
   $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
     [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
   $dbProp.SetValue($form, $true, $null)
   ```
3. **`snip.ps1` 必须带 UTF-8 BOM。** Windows PowerShell 5.1 对无 BOM 文件按 ANSI/CP936 解码，脚本里的中文注释和提示文字会被错切，导致 `Unexpected token '}'` 这类假语法错误（脚本其实没问题）。改完脚本要确认头三字节是 `239,187,191`：
   ```powershell
   $c = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
   [System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))
   ```
4. **`Clipboard::SetImage` 单写位图不够。** 见上一节，要 `DataObject` 同时放 `SetImage` + `SetFileDropList`，且 `SetDataObject($payload, $true)`（`copy: $true` 才能在本进程退出后保留）。
5. **`ms-screenclip:` 在渲染进程里跳不动。** 不是协议没注册（`HKCR\ms-screenclip` 有 `URL:ms-screenclip`，协议由 `Microsoft.ScreenSketch` AppX 注册），是 Electron 的 `onBeforeRequest` 白名单把它拦了。必须从 Host 侧 `Start-Process`。

## 改动后如何生效

- Host 侧（`index.js`）：在设置 → 插件里把本插件关闭再打开，或重启 DSH
- `snip.ps1`：每次点击都是新进程从磁盘读，改完**直接生效**，不用重载
- 客户端侧（`client.js`）：刷新窗口（`Ctrl+R`）
