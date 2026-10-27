import { expect, test } from 'claude-code/testing'
import { label } from './status'

test('label: same, different, none', () => {
  expect(label({ active: 'staging' }, { active: 'staging' })).toBe('AgentLens: staging')
  expect(label({ active: 'staging' }, { active: 'local' })).toBe('AgentLens: staging · Crafter: local')
  expect(label(null, { active: 'local' })).toBe('AgentLens: plugin settings · Crafter: local')
  expect(label({ active: null }, null)).toBe('AgentLens: plugin settings')
})

test('session start puts the active workspace on the status line', async ($, on) => {
  const files: Record<string, string> = {
    '/h/.config/agentlens/workspaces.json': '{"active":"prod","workspaces":{}}',
    '/h/.config/tm-agent-crafter/workspaces.json': '{"active":"local","workspaces":{}}',
  }
  const shown: (string | undefined)[] = []
  on('env.get', () => ({ value: '/h' }))
  on('fs.exists', (_, e) => ({ value: e.path in files }))
  on('fs.read', (_, e) => ({ value: files[e.path] }))
  on('clock.every', () => ({ value: () => {} }))
  on('ui.status', (_, e) => (shown.push(e.text), { value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(shown).toEqual(['AgentLens: prod · Crafter: local'])
})
