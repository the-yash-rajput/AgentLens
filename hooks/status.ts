import type { Register } from 'claude-code'

// Shows the active AgentLens workspace (and tm-agent-crafter's, when it differs) on the status line.
// Both files are written by scripts/agentlens_workspace.sh; tm-agent-crafter's also by /crafter-workspace.
type Workspaces = { active?: string | null }

export function label(lens: Workspaces | null, crafter: Workspaces | null): string {
  const mine = lens?.active ?? 'plugin settings'
  const theirs = crafter?.active
  return theirs && theirs !== mine ? `AgentLens: ${mine} · Crafter: ${theirs}` : `AgentLens: ${mine}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const home = await $.env.get('HOME')
    const read = async (path: string): Promise<Workspaces | null> => {
      if (!(await $.fs.exists(path))) return null
      return JSON.parse(await $.fs.read(path)) as Workspaces
    }
    let shown: string | undefined
    const refresh = async () => {
      let text: string
      try {
        text = label(
          await read(`${home}/.config/agentlens/workspaces.json`),
          await read(`${home}/.config/tm-agent-crafter/workspaces.json`),
        )
      } catch {
        text = 'AgentLens: workspaces.json unreadable'
      }
      if (text !== shown) $.ui.status((shown = text))
    }
    await refresh()
    // ponytail: polls two tiny files every 3s, because a switch made with `!` or /crafter-workspace
    // passes through no hook. Move to a file watch if the API grows one.
    $.clock.every(3000, () => void refresh())
    return next(e)
  })
}
