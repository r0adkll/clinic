import { expect, test } from 'claude-code/testing'

type Sent = { socketPath?: string; body: Record<string, unknown> }

const SOCKET = '/tmp/clinic/hook.sock'
const SESSION = '11111111-2222-3333-4444-555555555555'

/** Lets the mod's detached send chain run: it is not awaited by the hook that started it. */
async function drained(sent: Sent[], count: number): Promise<void> {
  for (let i = 0; i < 200 && sent.length < count; i++) await new Promise<void>(resolve => resolve())
}

test('forwards a settings hook event whole, marked as the mod\'s', { options: { socket: SOCKET } }, async ($, on) => {
  const sent: Sent[] = []
  on('http.fetch', ($$, e) => {
    sent.push({ socketPath: e.init?.socketPath, body: JSON.parse(e.init?.body ?? '{}') })
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('classic.Stop', () => ({}))

  await $.classic.Stop({ stop_hook_active: false, session_id: SESSION })
  await drained(sent, 1)

  expect(sent.length).toBe(1)
  expect(sent[0]?.socketPath).toBe(SOCKET)
  expect(sent[0]?.body.hook_event_name).toBe('Stop')
  expect(sent[0]?.body.session_id).toBe(SESSION)
  expect(sent[0]?.body._clinic_via).toBe('mod')
})

test('reports a tool call as PreToolUse, by name only', { options: { socket: SOCKET } }, async ($, on) => {
  const sent: Sent[] = []
  on('http.fetch', ($$, e) => {
    sent.push({ socketPath: e.init?.socketPath, body: JSON.parse(e.init?.body ?? '{}') })
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('session.id', () => ({ value: SESSION }))
  on('tool.call', () => ({ result: 'ok' }))

  await $.tool.call({ tool: 'Bash', command: 'echo secret' })
  await drained(sent, 1)

  const pre = sent.find(s => s.body.hook_event_name === 'PreToolUse')
  expect(pre?.body.tool_name).toBe('Bash')
  expect(pre?.body.session_id).toBe(SESSION)
  expect(JSON.stringify(pre?.body).includes('secret')).toBe(false)
})

test('sends nothing when Clinic gave it no socket', async ($, on) => {
  let fetches = 0
  on('http.fetch', () => {
    fetches += 1
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('classic.Stop', () => ({}))

  await $.classic.Stop({ stop_hook_active: false, session_id: SESSION })
  for (let i = 0; i < 50; i++) await new Promise<void>(resolve => resolve())

  expect(fetches).toBe(0)
})

const QUESTIONS = [
  { question: 'Which fruit?', header: 'Fruit', multiSelect: false, options: [{ label: 'Apple', description: 'Crisp' }, { label: 'Banana', description: 'Soft' }] },
]

test('a question answered in Clinic becomes the tool\'s result', { options: { socket: SOCKET } }, async ($, on) => {
  const sent: Sent[] = []
  on('http.fetch', ($$, e) => {
    if (e.url.includes('/answer')) {
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ answers: { 'Which fruit?': 'Banana' } }) } }
    }
    sent.push({ socketPath: e.init?.socketPath, body: JSON.parse(e.init?.body ?? '{}') })
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('session.id', () => ({ value: SESSION }))
  // The terminal dialog, open and unanswered.
  on('tool.call', { tool: 'AskUserQuestion' }, () => new Promise(() => {}))

  const answered = await $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'toolu_1', questions: QUESTIONS })

  expect((answered.result as { answers: unknown }).answers).toEqual({ 'Which fruit?': 'Banana' })
  const asked = sent.find(s => s.body.hook_event_name === 'AskQuestion')
  expect(asked?.body.tool_use_id).toBe('toolu_1')
  expect(asked?.body.questions).toEqual(QUESTIONS)
  expect(sent.some(s => s.body.hook_event_name === 'AskResolved')).toBe(false)
})

test('a question answered in the terminal is passed through, and Clinic is told', { options: { socket: SOCKET } }, async ($, on) => {
  const sent: Sent[] = []
  on('http.fetch', ($$, e) => {
    // Clinic has nothing yet, and holds the request.
    if (e.url.includes('/answer')) return new Promise(() => {})
    sent.push({ socketPath: e.init?.socketPath, body: JSON.parse(e.init?.body ?? '{}') })
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('session.id', () => ({ value: SESSION }))
  on('tool.call', { tool: 'AskUserQuestion' }, () => ({ result: { questions: QUESTIONS, answers: { 'Which fruit?': 'Apple' }, annotations: {} } }))

  const answered = await $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'toolu_2', questions: QUESTIONS })
  await drained(sent, 3)

  expect((answered.result as { answers: unknown }).answers).toEqual({ 'Which fruit?': 'Apple' })
  const resolved = sent.find(s => s.body.hook_event_name === 'AskResolved')
  expect(resolved?.body.tool_use_id).toBe('toolu_2')
  expect(resolved?.body.answers).toEqual({ 'Which fruit?': 'Apple' })
})

test('with no socket the dialog is left alone', async ($, on) => {
  let fetches = 0
  on('http.fetch', () => {
    fetches += 1
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('tool.call', { tool: 'AskUserQuestion' }, () => ({ result: { questions: QUESTIONS, answers: { 'Which fruit?': 'Apple' }, annotations: {} } }))

  const answered = await $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'toolu_3', questions: QUESTIONS })

  expect((answered.result as { answers: unknown }).answers).toEqual({ 'Which fruit?': 'Apple' })
  expect(fetches).toBe(0)
})
