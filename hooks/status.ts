import type { EngineInterface, HttpInit, PluginOptions, Register } from 'claude-code'

// Shows the active AgentLens workspace (and tm-agent-crafter's, when it differs) on the status line,
// with 🟢 when Zendesk, Langfuse and Crafter all answer, or 🔴 and what failed when one doesn't.
// Both files are written by scripts/agentlens_workspace.sh; tm-agent-crafter's also by /crafter-workspace.
// ponytail: the status line is plain text (the engine draws its own prefix), so the colour is an emoji.
type Workspace = Record<string, string | undefined>
type Workspaces = { active?: string | null; workspaces?: Record<string, Workspace> }
type Settings = Record<string, string>

const LENS_FIELDS = [
  'zendesk_subdomain', 'zendesk_email', 'zendesk_token',
  'langfuse_host', 'langfuse_public_key', 'langfuse_secret_key',
]
const PROBE_MS = 60_000

export function label(lens: Workspaces | null, crafter: Workspaces | null): string {
  const mine = lens?.active ?? 'plugin settings'
  const theirs = crafter?.active
  return theirs && theirs !== mine ? `AgentLens: ${mine} · Crafter: ${theirs}` : `AgentLens: ${mine}`
}

// Same precedence as scripts/require_settings.sh: the active workspace overrides the plugin settings
// field by field. Crafter comes from tm-agent-crafter's own file, as crafter_proxy.py reads it.
// The two defaults repeat plugin.json's, as export-env.sh does.
export function settings(options: PluginOptions, lens: Workspaces | null, crafter: Workspaces | null): Settings {
  const s: Settings = {
    zendesk_subdomain: 'turtlemintsupport',
    langfuse_host: 'https://langfuse-v3.sre.turtle-infra.com',
  }
  for (const [k, v] of Object.entries(options)) if (typeof v === 'string' && v) s[k] = v
  const ws = lens?.active ? lens.workspaces?.[lens.active] : undefined
  for (const k of LENS_FIELDS) if (ws?.[k]) s[k] = ws[k] as string
  const cw = crafter?.active ? crafter.workspaces?.[crafter.active] : undefined
  if (cw?.host && cw.api_key) {
    s.crafter_host = cw.host
    s.crafter_api_key = cw.api_key
  }
  return s
}

export function line(base: string, problems: string[]): string {
  return problems.length ? `🔴 ${base} · ${problems.join(', ')}` : `🟢 ${base} · connected`
}

// Resolves null when the service accepts the credentials, else a short reason. Never the response body.
async function probe($: EngineInterface, name: string, url: string, init: HttpInit, accepted = (_: string) => true): Promise<string | null> {
  try {
    const r = await $.http.fetch(url, init)
    if (r.status === 401 || r.status === 403) return `${name} auth failed (${r.status})`
    if (!r.ok) return `${name} HTTP ${r.status}`
    return accepted(r.text) ? null : `${name} auth failed`
  } catch {
    return `${name} unreachable`
  }
}

const strip = (host: string) => host.replace(/\/$/, '')

export async function problems($: EngineInterface, s: Settings): Promise<string[]> {
  const zendesk = !s.zendesk_token
    ? 'Zendesk token missing'
    : probe($, 'Zendesk', `https://${s.zendesk_subdomain}.zendesk.com/api/v2/users/me.json`, {
        headers: {
          Authorization: s.zendesk_email
            ? `Basic ${btoa(`${s.zendesk_email}/token:${s.zendesk_token}`)}`
            : `Bearer ${s.zendesk_token}`,
        },
        // Bad credentials still get 200 here, as the anonymous user with a null id.
      }, text => JSON.parse(text)?.user?.id != null)

  const langfuse = !s.langfuse_public_key || !s.langfuse_secret_key
    ? 'Langfuse keys missing'
    : probe($, 'Langfuse', `${strip(s.langfuse_host ?? '')}/api/public/projects`, {
        headers: { Authorization: `Basic ${btoa(`${s.langfuse_public_key}:${s.langfuse_secret_key}`)}` },
      })

  const crafter = !s.crafter_host || !s.crafter_api_key
    ? 'Crafter not configured'
    : probe($, 'Crafter', `${strip(s.crafter_host)}/api/agent-crafter/mcp`, {
        method: 'POST',
        headers: {
          Authorization: `ApiKey ${s.crafter_api_key}`,
          'Content-Type': 'application/json',
          Accept: 'application/json, text/event-stream',
        },
        body: JSON.stringify({
          jsonrpc: '2.0', id: 1, method: 'initialize',
          params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'agentlens-status', version: '1' } },
        }),
      })

  return (await Promise.all([zendesk, langfuse, crafter])).filter((p): p is string => p !== null)
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const home = await $.env.get('HOME')
    const read = async (path: string): Promise<Workspaces | null> => {
      if (!(await $.fs.exists(path))) return null
      return JSON.parse(await $.fs.read(path)) as Workspaces
    }
    let shown: string | undefined
    let probedKey = ''
    let probedAt = 0
    let found: string[] | null = null
    let busy = false
    const show = (text: string) => {
      if (text !== shown) $.ui.status((shown = text))
    }

    const refresh = async () => {
      if (busy) return
      busy = true
      try {
        let lens: Workspaces | null
        let crafter: Workspaces | null
        try {
          lens = await read(`${home}/.config/agentlens/workspaces.json`)
          crafter = await read(`${home}/.config/tm-agent-crafter/workspaces.json`)
        } catch {
          return show('🔴 AgentLens: workspaces.json unreadable')
        }
        const base = label(lens, crafter)
        const s = settings(options, lens, crafter)
        const key = JSON.stringify(s)
        const now = await $.clock.now()
        // Probe again on a switch or once a minute; the 3s tick only re-reads the two files.
        if (key !== probedKey || now - probedAt >= PROBE_MS) {
          if (key !== probedKey) show(`⚪ ${base} · checking…`)
          probedKey = key
          probedAt = now
          found = await problems($, s)
        }
        show(line(base, found ?? []))
      } finally {
        busy = false
      }
    }
    // Not awaited: the first probe is three network calls, and session start shouldn't wait on them.
    void refresh()
    // ponytail: polls two tiny files every 3s, because a switch made with `!` or /crafter-workspace
    // passes through no hook. Move to a file watch if the API grows one.
    $.clock.every(3000, () => void refresh())
    return next(e)
  })
}
