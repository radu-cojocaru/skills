export type SkillCall = {
  id: string
  skill: string
  args?: string
  turn: number
  isSubagent: boolean
  status: 'running' | 'done' | 'failed'
}

declare module 'claude-code' {
  interface PluginState {
    'skill-view': { calls: SkillCall[]; turn: number }
  }
}
