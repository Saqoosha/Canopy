import { expect, test } from 'claude-code/testing'

const CWD = '/work/project'

const denied = r => Boolean(r.deny || r.isError)

function engine(on, verdict = 'DENY not needed') {
  on('ui.log', () => ({ value: undefined }))
  on('session.cwd', () => ({ value: CWD }))
  // realpath: `link` inside the folder points outside it; everything else is itself.
  on('process.run', (_, e) => {
    const path = e.argv?.[1] ?? e.command?.[1] ?? ''
    return { value: { exitCode: 0, stdout: path === `${CWD}/link` ? '/private/etc/hosts\n' : `${path}\n`, stderr: '' } }
  })
  on('model.complete', (_, e) => ({ value: { isAnswered: true, text: /Classify/.test(String(e.prompt)) ? 'QUESTION' : verdict } }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('tool.call', () => ({ result: {} }))
}

const slack = '[canopy:slack] Taro asks: what is in notes.txt?'

test('a Slack question lets reads inside the folder through and nothing else', async ($, on) => {
  engine(on)
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/notes.txt` }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Grep', pattern: 'x' }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/.env` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/../other/secret.txt` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Glob', pattern: '/Users/**/*.txt' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Edit', file_path: `${CWD}/notes.txt`, old_string: 'a', new_string: 'b' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Write', file_path: `${CWD}/x`, content: 'b' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Bash', command: 'echo hi' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Read', file_path: `${CWD}/link` }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Grep', pattern: 'KEY', glob: '**/.env*' }))).toBe(true)
})

test('Haiku allowing a read outside the folder lets it through, and never Bash', async ($, on) => {
  engine(on, 'ALLOW it only reads the referenced doc')
  await $.prompt.submit({ text: slack })
  expect(denied(await $.tool.call({ tool: 'Read', file_path: '/work/other/doc.md' }))).toBe(false)
  expect(denied(await $.tool.call({ tool: 'Bash', command: 'ls' }))).toBe(true)
  expect(denied(await $.tool.call({ tool: 'Edit', file_path: `${CWD}/notes.txt`, old_string: 'a', new_string: 'b' }))).toBe(true)
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
