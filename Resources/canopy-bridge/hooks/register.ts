// Canopy reads these lines off the stream-json wire (system/ui_log, plugin
// "canopy-bridge") and never forwards them to the webview.
function worktreeLog($, ok, worktree, extra) {
  $.ui.log(JSON.stringify({ v: 1, ok, worktree, ...extra }))
}

// `$.process.run` defaults to the session's cwd, which may be the removed worktree.
async function env($, name) {
  return (await $.process.run(['printenv', name], { cwd: '/' })).stdout.trim()
}

async function realPath($, path) {
  const r = await $.process.run(['/bin/sh', '-c', 'cd "$1" && pwd -P', 'sh', path], { cwd: '/' })
  return r.exitCode === 0 ? r.stdout.trim() : ''
}

// Whether the command names `path`: in full, or as an argument ending in its last component.
function namesPath(command, path) {
  const name = path.split('/').pop()
  if (!name) return false
  for (let i = command.indexOf(path); i >= 0; i = command.indexOf(path, i + 1)) {
    if (!/[\w.-]/.test(command[i + path.length] ?? '')) return true  // not `${path}-2`
  }
  return command.split(/\s+/).some(raw => {
    const arg = raw.replace(/^[('"]+|[)'";&|]+$/g, '').replace(/\/+$/, '')
    return arg === name || arg.endsWith('/' + name)
  })
}

// Commands that delete a worktree folder: git's own removal, or deleting it outright.
const REMOVES = /\bworktree\s+remove\b|\brm\s+(?:-\w+\s+)*-\w*[rR]/

// The worktree this module is re-entering after a removal that did not happen.
let reentering
// Set when entering failed: the CLI is in the main checkout while Canopy shows the worktree.
let blocked

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
      const wt = await env($, 'CANOPY_WORKTREE')
      // A CLI re-spawned in this shim resumes inside the worktree already.
      if (!wt || r.cwd === wt) return r
      // Only the CLI the shim started in the checkout. A `claude` run from this
      // session's shell inherits the variable but starts somewhere else.
      const checkout = await env($, 'CANOPY_CLI_CWD')
      if (!checkout || await realPath($, r.cwd) !== await realPath($, checkout)) return r
      const res = await $.tool.call({ tool: 'EnterWorktree', path: wt })
      if (res.deny || res.isError) {
        blocked = `${res.deny ?? res.text ?? 'refused'}`
        worktreeLog($, false, `enter failed: ${blocked}`)
      } else {
        worktreeLog($, true, 'entered')
      }
    } catch (err) {
      blocked = String(err)
      worktreeLog($, false, `enter threw: ${blocked}`)
    }
    return r
  })

  // Entering a worktree outside `.claude/worktrees/` asks, and nobody is at the
  // prompt. Allow only this plugin's own call to the path it means to enter.
  on('tool.check', { tool: 'EnterWorktree' }, async ($, e, next) => {
    const verdict = await next(e)
    if (next.origin?.plugin !== $.plugin.name) return verdict
    const path = e.input?.path
    return path && (path === reentering || path === await env($, 'CANOPY_WORKTREE'))
      ? { decision: 'allow', reason: 'Canopy started this session for this worktree' }
      : verdict
  })

  // After a failed entry every tool would act on the main checkout.
  on('tool.call', async ($, e, next) => blocked
    ? { deny: `Canopy could not move this session into its worktree (${blocked}), so tools are blocked to keep the main checkout untouched. Close the pane and reopen the session from the sidebar.` }
    : next(e))

  // A removal leaves the transcript in the worktree's project folder; leaving
  // with ExitWorktree first moves it to the checkout's. If the worktree is still
  // there afterwards — the removal failed, or named another worktree — go back in.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = e.command ?? ''
    if (!REMOVES.test(command)) return next(e)
    const cwd = await $.session.cwd()
    if (!namesPath(command, cwd)) return next(e)
    const left = await $.tool.call({ tool: 'ExitWorktree', action: 'keep' })
    const checkout = left.result?.originalCwd
    // No checkout: this session did not enter through EnterWorktree (one started
    // inside the worktree), or the exit was refused. Nothing to move back.
    if (left.deny || left.isError || !checkout) {
      const why = left.deny ?? left.text ?? ''
      if ((left.deny || left.isError) && !/No-op/.test(why)) worktreeLog($, false, `exit before remove: ${why}`)
      return next(e)
    }
    try {
      // In the foreground, so the check below sees the removal's outcome.
      return await next({ ...e, run_in_background: false })
    } finally {
      try {
        if ((await $.process.run(['/bin/test', '-d', cwd], { cwd: '/' })).exitCode !== 0) {
          // Canopy moves the open pane to this checkout once the turn ends.
          worktreeLog($, true, 'exited before remove', { checkout })
        } else {
          reentering = cwd
          const back = await $.tool.call({ tool: 'EnterWorktree', path: cwd })
          if (back.deny || back.isError) {
            blocked = `re-entering failed: ${back.deny ?? back.text ?? ''}`
            worktreeLog($, false, `still in the checkout: ${blocked}`)
          } else {
            worktreeLog($, true, 'the worktree is still there; back in it')
          }
        }
      } catch (err) {
        worktreeLog($, false, `after remove threw: ${String(err)}`)
      } finally {
        reentering = undefined
      }
    }
  })
}
