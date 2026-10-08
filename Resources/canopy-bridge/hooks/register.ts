// Canopy reads these lines off the stream-json wire (system/ui_log, plugin
// "canopy-bridge") and never forwards them to the webview.
function worktreeLog($, worktree, extra) {
  $.ui.log(JSON.stringify({ v: 1, worktree, ...extra }))
}

// `$.process.run` defaults to the session's cwd, which may be the removed worktree.
async function canopyWorktree($) {
  return (await $.process.run(['printenv', 'CANOPY_WORKTREE'], { cwd: '/' })).stdout.trim()
}

// Whether one of the command's arguments is `path`, or ends in its last component.
function namesPath(command, path) {
  const name = path.split('/').pop()
  return !!name && command.split(/\s+/).some(raw => {
    const arg = raw.replace(/^['"]|['"]$/g, '').replace(/\/+$/, '')
    return arg === path || arg === name || arg.endsWith('/' + name)
  })
}

// The worktree this module is re-entering after a removal that did not happen.
let reentering

export function register(on) {
  on('session.measure', async ($, e, next) => {
    const r = await next(e)
    if (e.changed?.includes('context') && e.context) {
      $.ui.log(JSON.stringify({ v: 1, context: { tokens: e.context.tokens ?? null, window: e.context.window ?? null } }))
    }
    return r
  })

  // Enter the worktree Canopy named in CANOPY_WORKTREE. Why: `ShimProcess.worktreeEntry`.
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    try {
      const wt = await canopyWorktree($)
      // A CLI re-spawned in this shim resumes inside the worktree already.
      if (!wt || r.cwd === wt) return r
      const res = await $.tool.call({ tool: 'EnterWorktree', path: wt })
      worktreeLog($, res.deny || res.isError ? `enter failed: ${res.deny ?? res.text ?? ''}` : 'entered')
    } catch (err) {
      worktreeLog($, `enter threw: ${String(err)}`)
    }
    return r
  })

  // Entering a worktree outside `.claude/worktrees/` asks, and nobody is at the
  // prompt. Allow only this plugin's own call to the path it means to enter.
  on('tool.check', { tool: 'EnterWorktree' }, async ($, e, next) => {
    const verdict = await next(e)
    if (next.origin?.plugin !== $.plugin.name) return verdict
    const path = e.input?.path
    return path && (path === reentering || path === await canopyWorktree($))
      ? { decision: 'allow', reason: 'Canopy started this session for this worktree' }
      : verdict
  })

  // A git removal leaves the transcript in the worktree's project folder; leaving
  // with ExitWorktree first moves it to the checkout's. If the worktree is still
  // there afterwards — the removal failed, or named another worktree — go back in.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = e.command ?? ''
    if (!/\bworktree\s+remove\b/.test(command)) return next(e)
    const cwd = await $.session.cwd()
    if (!namesPath(command, cwd)) return next(e)
    const left = await $.tool.call({ tool: 'ExitWorktree', action: 'keep' })
    if (left.deny || left.isError) {
      worktreeLog($, `exit before remove: ${left.deny ?? left.text ?? ''}`)
      return next(e)
    }
    const ran = await next(e)
    try {
      if ((await $.process.run(['/bin/test', '-d', cwd], { cwd: '/' })).exitCode !== 0) {
        // Canopy moves the open pane to this checkout once the turn ends.
        worktreeLog($, 'exited before remove', { checkout: left.result?.originalCwd })
        return ran
      }
      reentering = cwd
      const back = await $.tool.call({ tool: 'EnterWorktree', path: cwd })
      worktreeLog($, back.deny || back.isError
        ? `still in the checkout: re-entering failed: ${back.deny ?? back.text ?? ''}`
        : 'the worktree is still there; back in it')
    } catch (err) {
      worktreeLog($, `after remove threw: ${String(err)}`)
    } finally {
      reentering = undefined
    }
    return ran
  })
}
