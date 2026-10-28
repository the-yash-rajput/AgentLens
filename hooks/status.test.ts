import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import { label, line, settings } from './status'

test('label: same, different, none', () => {
  expect(label({ active: 'staging' }, { active: 'staging' })).toBe('AgentLens: staging')
  expect(label({ active: 'staging' }, { active: 'local' })).toBe('AgentLens: staging · Crafter: local')
  expect(label(null, { active: 'local' })).toBe('AgentLens: plugin settings · Crafter: local')
  expect(label({ active: null }, null)).toBe('AgentLens: plugin settings')
})

test('line: green when nothing failed, red naming each failure', () => {
  expect(line('AgentLens: prod', [])).toBe('🟢 AgentLens: prod · connected')
  expect(line('AgentLens: prod', ['Langfuse auth failed (401)', 'Crafter unreachable']))
    .toBe('🔴 AgentLens: prod · Langfuse auth failed (401), Crafter unreachable')
})

test('settings: workspace overrides plugin options; Crafter comes from its own file', () => {
  const s = settings(
    { langfuse_public_key: 'pk-opt', langfuse_secret_key: 'sk-opt', crafter_host: 'https://opt', crafter_api_key: 'k-opt' },
    { active: 'prod', workspaces: { prod: { langfuse_public_key: 'pk-ws', crafter_host: 'https://ignored' } } },
    { active: 'prod', workspaces: { prod: { host: 'https://crafter', api_key: 'k-ws' } } },
  )
  expect(s.langfuse_public_key).toBe('pk-ws')
  expect(s.langfuse_secret_key).toBe('sk-opt')
  expect(s.langfuse_host).toBe('https://langfuse-v3.sre.turtle-infra.com')
  expect(s.crafter_host).toBe('https://crafter')
  expect(s.crafter_api_key).toBe('k-ws')
})

const files: Record<string, string> = {
  '/h/.config/agentlens/workspaces.json': '{"active":"prod","workspaces":{}}',
  '/h/.config/tm-agent-crafter/workspaces.json':
    '{"active":"local","workspaces":{"local":{"host":"https://crafter","api_key":"k"}}}',
}

// Stands in for the engine; resolves with every status shown once a 🟢/🔴 line lands.
function wire(on: On, answer: (url: string) => { status: number; text?: string } | 'down') {
  const shown: (string | undefined)[] = []
  let settle: (v: (string | undefined)[]) => void = () => {}
  const settled = new Promise<(string | undefined)[]>(r => (settle = r))
  on('env.get', () => ({ value: '/h' }))
  on('fs.exists', (_, e) => ({ value: e.path in files }))
  on('fs.read', (_, e) => ({ value: files[e.path] ?? '' }))
  on('clock.now', () => ({ value: 1_000_000 }))
  on('clock.every', () => ({ value: undefined }))
  on('http.fetch', (_, e) => {
    const a = answer(e.url)
    if (a === 'down') throw new Error('connect ECONNREFUSED')
    return { value: { status: a.status, ok: a.status < 400, headers: {}, text: a.text ?? '{}' } }
  })
  on('ui.status', (_, e) => {
    shown.push(e.text)
    if (/^(🟢|🔴)/u.test(e.text ?? '')) settle(shown)
    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  return settled
}

const options = { zendesk_token: 't', zendesk_email: 'a@b.c', langfuse_public_key: 'pk', langfuse_secret_key: 'sk' }
const start = { cwd: '/', surface: 'terminal', isInteractive: true } as const

test('all three accept the credentials: checking, then green', { options }, async ($, on) => {
  const shown = wire(on, url => (url.includes('zendesk') ? { status: 200, text: '{"user":{"id":7}}' } : { status: 200 }))
  await $.session.start(start)
  expect(await shown).toEqual([
    '⚪ AgentLens: prod · Crafter: local · checking…',
    '🟢 AgentLens: prod · Crafter: local · connected',
  ])
})

test('any failure turns it red and names each one', { options }, async ($, on) => {
  const shown = wire(on, url =>
    url.includes('zendesk') ? { status: 200, text: '{"user":{"id":null}}' }
      : url.includes('langfuse') ? { status: 401 }
        : 'down')
  await $.session.start(start)
  expect((await shown).at(-1)).toBe(
    '🔴 AgentLens: prod · Crafter: local · Zendesk auth failed, Langfuse auth failed (401), Crafter unreachable',
  )
})

test('missing secrets are reported without a request', async ($, on) => {
  const shown = wire(on, () => ({ status: 200 }))
  await $.session.start(start)
  expect((await shown).at(-1)).toBe('🔴 AgentLens: prod · Crafter: local · Zendesk token missing, Langfuse keys missing')
})
