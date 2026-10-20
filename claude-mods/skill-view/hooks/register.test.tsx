import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'skill-view',
  component: 'Pane',
  requestId: 'skill-view',
  props: {
    title: 'Skills',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

test('the pane lists a skill Claude invoked, grouped by turn', async ($, on) => {
  on('command.register', () => ({ value: { command: 'skill-view' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('tool.call', () => ({ result: {} }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.tool.call({ tool: 'Skill', skill: 'commit' })

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /Turn 1/ })).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /commit/ }))?.text).toBe('✓ commit')
    await ui.unmount()
  }
})

test('the pane says so when no skill was invoked', async ($) => {
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /No skills/ })).toBeDefined()
  await ui.unmount()
})
