import { expect, test } from 'claude-code/testing'

const HOME = '/Users/me'
const CWD = `${HOME}/work/project`

const denied = r => Boolean(r.deny || r.isError)

// Stands for the engine. `seen` records what each tool call reached the engine with.
function engine(on, { cwd = CWD } = {}) {
  const seen = []
  const logs = []
  on('ui.log', (_, e) => { logs.push(String(e.text ?? e)); return { value: undefined } })
  on('session.cwd', () => ({ value: cwd }))
  on('model.complete', () => ({ value: { isAnswered: true, text: 'QUESTION' } }))
  // printenv HOME, and realpath: `link` inside the folder points outside it.
  on('process.run', (_, e) => {
    const argv = e.argv ?? e.command ?? []
    if (argv[0] === 'printenv') return { value: { exitCode: 0, stdout: `${argv[1] === 'HOME' ? HOME : ''}\n`, stderr: '' } }
    const path = argv[1] ?? ''
    return { value: { exitCode: 0, stdout: path === `${CWD}/link` ? '/private/etc/hosts\n' : `${path}\n`, stderr: '' } }
  })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('tool.call', (_, e) => { seen.push(e); return { result: {} } })
  return { seen, logs }
}

const slack = '[canopy:slack] Taro asks: what is in notes.txt?'

test('a Slack question lets reads inside the folder through and nothing else', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/notes.txt` }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: 'src/app.ts' }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Glob', pattern: 'src/**/*.ts' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Grep', pattern: 'TOKEN' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/.env` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/secrets/prod.yml` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/../other/doc.md` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: '~/.config/gh/hosts.yml' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/link` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Edit', file_path: `${CWD}/notes.txt`, old_string: 'a', new_string: 'b' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Bash', command: 'ls' }))).toBe(true)
})

test('only reads pass: every other tool, known or not, is refused', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  for (const call of [
    { tool: 'WebFetch', url: 'https://example.com', prompt: 'x' },
    { tool: 'Agent', description: 'x', prompt: 'x' },
    { tool: 'Task', description: 'x', prompt: 'x' },
    { tool: 'NotebookEdit', notebook_path: `${CWD}/a.ipynb`, new_source: 'x' },
    { tool: 'mcp__saqoolaude__slack_post', channel: 'C1', text: 'x' },
    { tool: 'MadeUpTool' },
  ]) expect(denied(await $.tool.call(call))).toBe(true)
})

test('credential names are refused wherever they sit, and a sibling folder is outside', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  for (const name of ['id_rsa', 'x.pem', 'server.key', '.netrc', '.npmrc', 'credentials.json', '.git-credentials', '.git/config', 'config/secrets.yml'])
    expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/${name}` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}-secrets/a.txt` }))).toBe(true)
})

test('the gate stays through a folded-in prompt, a hidden one, a slash command and a notification', async ($, on) => {
  engine(on)
  const write = () => $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' })
  await $.prompt.submit({ text: slack })
  await $.prompt.submit({ text: 'and also', turnId: 't1' })
  expect(denied(await write())).toBe(true)
  await $.prompt.submit({ text: 'hidden', isMeta: true })
  expect(denied(await write())).toBe(true)
  await $.prompt.submit({ text: '/compact', command: { name: 'compact', args: '' } })
  expect(denied(await write())).toBe(true)
  await $.prompt.submit({ text: 'task done', origin: { kind: 'task-notification' } })
  expect(denied(await write())).toBe(true)
  await $.prompt.submit({ text: 'fix it', origin: { kind: 'sdk' } })
  expect(denied(await write())).toBe(false)
})

test('a name that is a link to a key is refused by the name asked for', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  for (const name of ['.dev.vars', 'prod.env', 'k.p8', '.kube/config', '.mcp.json', ' .env', 'api_token.txt'])
    expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/${name}` }))).toBe(true)
})

test('a mark inside joined queued prompts still arms the gate', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: `fix X\n${slack}` })
  expect(denied(await $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' }))).toBe(true)
})

test('credential names are judged below the folder, so a project path containing one still reads', async ($, on) => {
  engine(on, { cwd: `${HOME}/repos/token-service` })
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${HOME}/repos/token-service/README.md` }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${HOME}/repos/token-service/.env` }))).toBe(true)
})

test('a session rooted at the home folder reads nothing from Slack', async ($, on) => {
  engine(on, { cwd: HOME })
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${HOME}/notes.txt` }))).toBe(true)
})

test('a session rooted inside ~/.ssh reads nothing from Slack', async ($, on) => {
  engine(on, { cwd: `${HOME}/.ssh` })
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${HOME}/.ssh/config` }))).toBe(true)
})

test('a plain prompt from the person lifts the gate', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' }))).toBe(true)
  await $.prompt.submit({ text: 'append ok to notes.txt' })
  expect(denied(await $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' }))).toBe(false)
})

test('without a Slack question nothing is gated', async ($, on) => {
  engine(on)
  expect(denied(await $.tool.call({ tool: 'Bash', command: 'rm -f x' }))).toBe(false)
})

test('the session tells Canopy the Slack gate is loaded', async ($, on) => {
  const { logs } = engine(on)
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: false })
  expect(logs.some(line => line.includes('"ready":true'))).toBe(true)
})
