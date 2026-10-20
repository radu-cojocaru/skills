import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { SkillCall } from '../types'

const PANE = 'skill-view'
const KEEP = 200
const calls = atom({ plugin: 'skill-view', key: 'calls' } as const, [])
const turn = atom({ plugin: 'skill-view', key: 'turn' } as const, 0)

const GLYPH = { running: '…', done: '✓', failed: '✗' } as const

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'skill-view',
      description: 'Show the skills Claude invoked on its own in a pane',
    })
    void $.ui.open({ id: PANE, title: 'Skills' })

    return next(e)
  })

  on('command.run', { command: 'skill-view' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Skills' })

    return { text: 'Skills pane opened.' }
  })

  // A new prompt on the main loop starts a new turn; a subagent's run does not.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) await update($, turn, n => n + 1)

    return next(e)
  })

  // The Skill tool is how Claude invokes a skill itself; a skill the person
  // types as /name never passes through it.
  on('tool.call', { tool: 'Skill' }, async ($, e, next) => {
    const call: SkillCall = {
      id: e.tool_use_id,
      skill: e.skill,
      args: e.args,
      turn: await read($, turn),
      isSubagent: e.agentId !== undefined,
      status: 'running',
    }
    await update($, calls, list => [...list, call].slice(-KEEP))

    const ran = await next(e)
    const status = ran.deny !== undefined || ran.isError === true ? 'failed' : 'done'
    await update($, calls, list =>
      list.map(one => (one.id === call.id ? { ...one, status } : one)),
    )

    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, calls)
    const current = await read($, turn)

    if (list.length === 0) {
      return <Text dimColor>No skills invoked automatically yet.</Text>
    }

    // Newest turn first, as many rows as the pane has room for.
    const room = Math.max(1, (e.viewport?.rows ?? 24) - 4)
    const rows: { turn: number; calls: SkillCall[] }[] = []
    for (const call of [...list].reverse()) {
      const last = rows[rows.length - 1]
      if (last && last.turn === call.turn) last.calls.unshift(call)
      else rows.push({ turn: call.turn, calls: [call] })
    }

    const shown: unknown[] = []
    let used = 0
    for (const group of rows) {
      if (used + 1 + group.calls.length > room && shown.length > 0) break
      used += 1 + group.calls.length
      shown.push(
        <Box flexDirection="column">
          <Text bold dimColor={group.turn !== current}>
            Turn {group.turn}
          </Text>
          {group.calls.map(call => (
            <Text dimColor={call.status === 'done'}>
              {GLYPH[call.status]} {call.skill}
              {call.isSubagent ? ' (subagent)' : ''}
              {call.args ? ` ${call.args}` : ''}
            </Text>
          ))}
        </Box>,
      )
    }

    return (
      <Box flexDirection="column">
        <Text dimColor>
          {list.length} invoked automatically over {current} turn{current === 1 ? '' : 's'}
        </Text>
        {shown}
      </Box>
    )
  })
}
