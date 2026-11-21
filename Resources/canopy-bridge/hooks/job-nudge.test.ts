import { expect, test } from 'claude-code/testing'

// Stands for the engine: a store, a clock the test moves, and Bash that always succeeds.
function engine(on) {
  const clock = { now: 1_000_000 }
  const store = new Map()
  on('ui.log', () => ({ value: undefined }))
  on('session.id', () => ({ value: 'sid' }))
  on('session.cwd', () => ({ value: '/Users/me/work' }))
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.set', (_, e) => { store.set(e.key, e.value); return { value: undefined } })
  on('store.delete', (_, e) => { store.delete(e.key); return { value: undefined } })
  on('clock.now', () => ({ value: clock.now }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '' } }))
  on('tool.call', (_, e) => (e.command === 'refused' ? { deny: 'no' } : { result: {} }))
  return clock
}

const nudged = r => (r.context ?? []).some(c => /job-watch/.test(c))

test('a nohup job with nothing registered gets one note', async ($, on) => {
  engine(on)
  const r = await $.tool.call({ tool: 'Bash', command: 'nohup python train.py > log 2>&1 &' })
  expect(nudged(r)).toBe(true)
})

test('a background run and a detached tmux count as long jobs', async ($, on) => {
  const clock = engine(on)
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'python render.py', run_in_background: true }))).toBe(true)
  clock.now += 31 * 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'tmux new -d -s r "python r.py"' }))).toBe(true)
  clock.now += 31 * 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: "ssh rt4090 'cd w && ./train.sh' &" }))).toBe(true)
})

test('ordinary commands get nothing', async ($, on) => {
  engine(on)
  for (const command of ['ls -la', 'git status', 'echo a & b', 'grep -c png renders']) {
    expect(nudged(await $.tool.call({ tool: 'Bash', command }))).toBe(false)
  }
})

test('at most one note in 30 minutes', async ($, on) => {
  const clock = engine(on)
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup a &' }))).toBe(true)
  clock.now += 29 * 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup b &' }))).toBe(false)
  clock.now += 2 * 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup c &' }))).toBe(true)
})

test('no note once the session has registered a job', async ($, on) => {
  const clock = engine(on)
  await $.tool.call({ tool: 'Bash', command: 'canopyctl job watch --session-id "$CLAUDE_SESSION_ID" --label x --probe "echo 1/2"' })
  clock.now += 60 * 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup python train.py &' }))).toBe(false)
})

test('a refused call gets no note', async ($, on) => {
  engine(on)
  const r = await $.tool.call({ tool: 'Bash', command: 'refused', run_in_background: true })
  expect(r.deny).toBe('no')
  expect(nudged(r)).toBe(false)
})

test('clearing the job brings the note back for the next one', async ($, on) => {
  const clock = engine(on)
  await $.tool.call({ tool: 'Bash', command: 'canopyctl job watch --session-id x --label a --probe "echo 1/2"' })
  await $.tool.call({ tool: 'Bash', command: 'canopyctl job clear --session-id x' })
  clock.now += 60_000
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup python train.py &' }))).toBe(true)
})

test('asking for help is not a registration', async ($, on) => {
  engine(on)
  await $.tool.call({ tool: 'Bash', command: 'canopyctl job watch --help' })
  expect(nudged(await $.tool.call({ tool: 'Bash', command: 'nohup python train.py &' }))).toBe(true)
})
