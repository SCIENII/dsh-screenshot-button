import { execFile } from 'node:child_process'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(HERE, 'snip.ps1')
const POWERSHELL = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

export const inject = ['commands']

/**
 * Run the region-snipper on the Host process (not the Electron renderer,
 * whose session denies display capture, clipboard permissions and custom
 * protocol navigation).
 * @param full - capture the whole virtual screen without an overlay.
 * @returns captured file path and whether the image reached the clipboard.
 */
function runSnip(full) {
  const stamp = new Date().toISOString().replace(/[:.]/gu, '-')
  const out = join(tmpdir(), 'dsh-snips', `snip-${stamp}.png`)
  const args = [ '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Out', out ]
  if (full) args.push('-Full')

  return new Promise((resolve, reject) => {
    execFile(POWERSHELL, args, { windowsHide: true, timeout: 300_000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
      const text = `${stdout ?? ''}\n${stderr ?? ''}`
      if (/^CANCEL$/mu.test(stdout ?? '')) return resolve({ cancelled: true })
      if (error) {
        const detail = (stderr ?? '').trim().split(/\r?\n/u).filter(Boolean).pop() ?? error.message
        return reject(new Error(detail))
      }
      const ok = /^OK:(.+)$/mu.exec(stdout ?? '')
      if (!ok) return reject(new Error(text.trim().split(/\r?\n/u).filter(Boolean).pop() ?? 'screenshot produced no output'))
      resolve({ cancelled: false, path: ok[1].trim(), copied: /^COPIED:true$/mu.test(stdout ?? '') })
    })
  })
}

export function apply(ctx) {
  ctx.effect(() => ctx.commands.register({
    name: 'snip',
    description: '区域截图，圈选后自动复制到剪贴板（输入 full 截整屏）',
    input: { hint: 'full' },
    handler: async ({ rawInput }) => {
      const full = /^\s*full\s*$/iu.test(rawInput ?? '')
      try {
        const result = await runSnip(full)
        if (result.cancelled) return { kind: 'success', text: '截图已取消' }
        return {
          kind: 'success',
          text: result.copied
            ? '截图已复制到剪贴板，回到输入框按 Ctrl+V 粘贴'
            : `截图已保存到 ${result.path}（剪贴板写入未完成，可直接拖入输入框）`,
        }
      } catch (error) {
        return { kind: 'error', text: `截图失败：${error instanceof Error ? error.message : String(error)}` }
      }
    },
  }))
}
