window.__ModuleLoader__.load({
  id: '@local/screenshot-button',
  factory(require) {
    const React = require('react')

    const NS = 'screenshot-button'
    const dicts = {
      zh: {
        'button.title': '截图（左键区域 / 右键整屏）',
        'button.busy': '截图中…',
        'error.remote': '截图服务未就绪，请刷新界面',
        'error.missing': '/snip 命令不可用：宿主插件未加载，重启 DSH 后重试',
        'error.prefix': '截图失败：',
      },
      en: {
        'button.title': 'Screenshot (click: region / right-click: full)',
        'button.busy': 'Capturing…',
        'error.remote': 'Screenshot service unavailable, reload the window',
        'error.missing': '/snip is unavailable: host plugin not loaded, restart DSH',
        'error.prefix': 'Screenshot failed: ',
      },
    }

    function ScissorsIcon() {
      return React.createElement(
        'svg',
        { width: 16, height: 16, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': 'true' },
        React.createElement('path', { d: 'M4 4l10.5 10.5' }),
        React.createElement('path', { d: 'M4 20l10.5-10.5' }),
        React.createElement('circle', { cx: 18.5, cy: 6.5, r: 2.5 }),
        React.createElement('circle', { cx: 18.5, cy: 17.5, r: 2.5 }),
      )
    }

    function showToast(text, signal) {
      if (typeof document === 'undefined' || !document.body) return
      const node = document.createElement('div')
      node.textContent = text
      node.style.cssText = [
        'position:fixed',
        'left:50%',
        'bottom:96px',
        'transform:translateX(-50%)',
        'max-width:min(72vw,560px)',
        'padding:8px 14px',
        'border-radius:10px',
        'background:rgba(24,26,32,.92)',
        'color:#f4f6fa',
        'font:13px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif',
        'box-shadow:0 8px 24px rgba(0,0,0,.28)',
        'z-index:2147483000',
        'pointer-events:none',
        'white-space:pre-wrap',
      ].join(';')
      document.body.appendChild(node)
      const timer = setTimeout(() => node.remove(), 4200)
      if (signal) {
        signal.addEventListener('abort', () => {
          clearTimeout(timer)
          node.remove()
        })
      }
    }

    function commandsRemote(ctx) {
      const read = (key) => (typeof ctx.get === 'function' ? ctx.get(key) : undefined)
      const direct = read('remote.commands') ?? ctx['remote.commands']
      if (direct) return direct
      const remote = read('remote') ?? ctx.remote
      return remote?.commands
    }

    async function triggerSnip(ctx, t, sessionId, full) {      const commands = commandsRemote(ctx)
      if (!commands || typeof commands.execute !== 'function') {
        showToast(t('error.remote'))
        return
      }
      if (!sessionId) {
        showToast(t('error.missing'))
        return
      }
      const line = full ? '/snip full' : '/snip'
      try {
        const response = await commands.execute(sessionId, line, [])
        if (!response || response.ok !== true) {
          showToast(`${t('error.prefix')}${response?.error?.message ?? 'request rejected'}`)
          return
        }
        const execution = response.value
        if (!execution) {
          showToast(t('error.missing'))
          return
        }
        const outcome = execution.result
        if (!outcome) {
          showToast(t('error.missing'))
          return
        }
        if (outcome.kind === 'error') {
          showToast(outcome.text ?? t('error.prefix'))
          return
        }
        if (outcome.text) showToast(outcome.text)
      } catch (error) {
        showToast(`${t('error.prefix')}${error instanceof Error ? error.message : String(error)}`)
      }
    }

    function ScreenshotButton({ t, sessionId, shoot }) {
      const [busy, setBusy] = React.useState(false)

      const start = React.useCallback(
        async (full) => {
          if (busy) return
          setBusy(true)
          try {
            await shoot(full, t)
          } finally {
            setBusy(false)
          }
        },
        [busy, shoot, t],
      )

      return React.createElement(
        'button',
        {
          type: 'button',
          title: busy ? t('button.busy') : t('button.title'),
          'aria-label': t('button.title'),
          disabled: busy,
          onMouseDown: (event) => event.preventDefault(),
          onClick: (event) => {
            event.preventDefault()
            void start(false)
          },
          onContextMenu: (event) => {
            event.preventDefault()
            void start(true)
          },
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            width: 32,
            height: 32,
            padding: 0,
            border: 'none',
            borderRadius: 8,
            background: 'transparent',
            color: 'inherit',
            cursor: busy ? 'progress' : 'pointer',
            opacity: busy ? 0.5 : 0.8,
          },
        },
        React.createElement(ScissorsIcon),
      )
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, dicts))

        ctx.slots.inject('conversation.input.right', () =>
          ctx.slots.register(
            {
              name: 'conversation.input.right',
              id: 'screenshot-button',
              locale: NS,
              order: 50,
              inject: (sessionId) => ({
                sessionId,
                shoot: (full, t) => triggerSnip(ctx, t, sessionId, full),
              }),
            },
            ScreenshotButton,
          ),
        )
      },
    }
  },
})
