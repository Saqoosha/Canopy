// Canopy reads these lines off the stream-json wire (system/ui_log, plugin
// "canopy-bridge") and never forwards them to the webview.
function worktreeLog($, worktree, extra) {
  $.ui.log(JSON.stringify({ v: 1, worktree, ...extra }))
}

async function canopyWorktree($) {
  return (await $.process.run(['printenv', 'CANOPY_WORKTREE'])).stdout.trim()
}

export function register(on) {
  on('session.measure', async ($, e, next) => {
    const r = await next(e)
    if (e.changed?.includes('context') && e.context) {
      $.ui.log(JSON.stringify({ v: 1, context: { tokens: e.context.tokens ?? null, window: e.context.window ?? null } }))
    }
    return r
  })

  // Worktree sessions. Canopy starts a fresh session's CLI in the main checkout
  // and names the worktree in CANOPY_WORKTREE (`ShimProcess.worktreeEntry`), so
  // the session ENTERS it here. Entering writes `relocated` records, and leaving
  // with ExitWorktree moves the transcript back to the main checkout's project
  // folder — which is what keeps the session openable after the worktree is
  // removed. A session started inside the worktree has no checkout to return
  // to: ExitWorktree answers it with a no-op, and its transcript is stranded.
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    try {
      const wt = await canopyWorktree($)
      // A resume restores the worktree on its own, so the CLI reports it here.
      if (!wt || r.cwd === wt) return r
      const res = await $.tool.call({ tool: 'EnterWorktree', path: wt })
      worktreeLog($, res.deny || res.isError ? `enter failed: ${res.deny ?? res.text ?? ''}` : 'entered')
    } catch (err) {
      worktreeLog($, `enter threw: ${String(err)}`)
    }
    return r
  })

  // Entering a worktree outside `.claude/worktrees/` asks for permission, and
  // nobody is at the prompt yet. Allow only this plugin's own call to the path
  // Canopy named; every other EnterWorktree keeps the engine's verdict.
  on('tool.check', { tool: 'EnterWorktree' }, async ($, e, next) => {
    const verdict = await next(e)
    if (next.origin?.plugin !== $.plugin.name) return verdict
    const wt = await canopyWorktree($)
    return wt && e.input?.path === wt
      ? { decision: 'allow', reason: 'Canopy started this session for this worktree' }
      : verdict
  })

  // Removing the session's own worktree with git leaves the transcript in the
  // worktree's project folder: the shell moves, the transcript does not. Leave
  // with ExitWorktree first, which moves it. A session that never entered
  // through EnterWorktree gets a no-op and the command runs unchanged.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (/\bworktree\s+remove\b/.test(e.command ?? '')) {
      const cwd = await $.session.cwd()
      const name = cwd.split('/').pop()
      if (name && e.command.includes(name)) {
        const res = await $.tool.call({ tool: 'ExitWorktree', action: 'keep' })
        if (res.deny || res.isError) {
          worktreeLog($, `exit before remove: ${res.deny ?? res.text ?? ''}`)
        } else {
          // Canopy moves the open pane to this checkout once the turn ends
          // with the worktree gone (`ShimProcess.checkoutAfterRemoval`).
          worktreeLog($, 'exited before remove', { checkout: res.result?.originalCwd })
        }
      }
    }
    return next(e)
  })
}
