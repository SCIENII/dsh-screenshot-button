import { execFile } from 'node:child_process'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(HERE, 'snip.ps1')
const POWERSHELL = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

export const inject = ['commands']

/** Words accepted after /snip, mapped to the snip.ps1 arguments they select. */
const VARIANTS = [
  { pattern: /^\s*$/u, args: [] },
  { pattern: /^\s*full\s*$/iu, args: ['-Mode', 'full'] },
  { pattern: /^\s*(overlay|self)\s*$/iu, args: ['-Engine', 'overlay'] },
  { pattern: /^\s*native\s*$/iu, args: ['-Engine', 'native'] },
  // Self-check: drives a rectangle through the snipping overlay by itself, so the
  // whole capture chain can be proven without touching the mouse.
  { pattern: /^\s*(probe|selftest|自检)\s*$/iu, args: ['-Probe'] },
]

/**
 * Run the snipper in the Host process. The Electron renderer cannot do this:
 * its session denies display capture, clipboard permissions and custom
 * protocol navigation, so region selection has to happen outside the page.
 * @param args - extra snip.ps1 switches selecting the capture variant.
 * @returns the captured path and whether it reached the clipboard.
 */
function runSnip(args) {
  const stamp = new Date().toISOString().replace(/[:.]/gu, '-')
  const out = join(tmpdir(), 'dsh-snips', `snip-${stamp}.png`)
  const argv = [ '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Out', out, ...args ]

  return new Promise((resolve, reject) => {
    execFile(POWERSHELL, argv, { windowsHide: true, timeout: 300_000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
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
    description: '区域截图（用系统截图工具，Esc 取消；输入 full 截整屏，overlay 用插件自绘覆盖层）',
    input: { hint: 'full | overlay | native | probe' },
    handler: async ({ rawInput }) => {
      const variant = VARIANTS.find(entry => entry.pattern.test(rawInput ?? '')) ?? VARIANTS[0]
      try {
        const result = await runSnip(variant.args)
        if (result.cancelled) return { kind: 'success', text: '截图已取消' }
        return {
          kind: 'success',
          text: result.copied
            ? '截图已在剪贴板，回到输入框按 Ctrl+V 粘贴（也可直接把图片拖进来）'
            : `截图已保存到 ${result.path}（剪贴板写入未完成，可直接拖入输入框）`,
        }
      } catch (error) {
        return { kind: 'error', text: `截图失败：${error instanceof Error ? error.message : String(error)}` }
      }
    },
  }))
}
