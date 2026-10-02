// Clinic's session mod (ADR-177): reports what a Claude Code session is doing to the Clinic that
// launched it, from inside the CLI, where the settings hooks used to start a helper process per event.
//
// Everything goes to Clinic's hook socket as one HTTP POST per event, in the order it happened. The
// settings hooks' events are forwarded as the CLI hands them over, so Clinic's state machine reads
// the same payloads either way. Three things have no settings hook and are added here: the status
// line's figures (so Clinic no longer has to take the user's status line to get them), the reason a
// turn ended (an interrupt fires no Stop hook), and a notice that this mod is loaded.
//
// The mod never changes an event: every hook passes its input on untouched, and a failure to reach
// Clinic is swallowed. Loaded with no socket configured, it does nothing.
import type { EngineInterface, Register } from 'claude-code'

type Payload = Record<string, unknown>

/** Events that begin or end a state get retries: losing one leaves the sidebar wrong (ADR-167). */
const PATIENT_RETRY_MS = [100, 400, 1500]

let socket = ''
/** Sends are chained so events arrive in the order they happened, whatever each one's latency. */
let queue: Promise<void> = Promise.resolve()
/** The last effort a main-loop request named; the engine offers it nowhere else. */
let effort: string | undefined
/** The last status report sent, so an unchanged one is not sent again. */
let lastStatus = ''

async function post($: EngineInterface, payload: Payload, isPatient: boolean): Promise<void> {
  const body = JSON.stringify({ ...payload, _clinic_via: 'mod' })
  const delays = isPatient ? [0, ...PATIENT_RETRY_MS] : [0]
  for (const delay of delays) {
    try {
      if (delay > 0) await $.clock.sleep(delay)
      const response = await $.http.fetch('http://clinic/hook', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body,
        socketPath: socket,
      })
      if (response.ok) return
    } catch {
      // Clinic is gone or rebinding its socket; the next delay, or nothing.
    }
  }
}

function send($: EngineInterface, payload: Payload, isPatient = true): Promise<void> {
  if (!socket) return queue
  queue = queue.then(() => post($, payload, isPatient))
  return queue
}

/** The status line's input, in the shape Clinic already decodes (ADR-157), built from the engine. */
async function reportStatus($: EngineInterface, model?: string): Promise<void> {
  if (!socket) return
  try {
    const [sessionId, usage, sessionModel] = await Promise.all([
      $.session.id(),
      $.session.usage(),
      model === undefined ? $.session.model() : Promise.resolve(model),
    ])
    const rateLimits: Record<string, { used_percentage: number; resets_at: number }> = {}
    for (const limit of usage.rateLimits) {
      const resetsAt = limit.resetsAt === undefined ? Number.NaN : Date.parse(limit.resetsAt)
      if (!Number.isNaN(resetsAt)) {
        rateLimits[limit.kind] = { used_percentage: limit.percentUsed, resets_at: Math.round(resetsAt / 1000) }
      }
    }
    const report: Payload = {
      context_window: {
        used_percentage: usage.context.percent,
        context_window_size: usage.context.window,
        total_input_tokens: usage.context.tokens,
      },
      model: { id: sessionModel },
      rate_limits: rateLimits,
    }
    if (effort !== undefined) report.effort = { level: effort }
    const fingerprint = sessionId + JSON.stringify(report)
    if (fingerprint === lastStatus) return
    lastStatus = fingerprint
    void send($, { hook_event_name: 'StatusLine', session_id: sessionId, ...report }, false)
  } catch {
    // A figure the engine cannot give yet; the next step reports.
  }
}

export const register: Register = (on, options) => {
  socket = typeof options.socket === 'string' ? options.socket : ''

  // The settings hooks' events (ADR-027), each forwarded whole. They fire whether or not a settings
  // hook is configured, and every one is passed on, so the user's own hooks run as they always did.
  on('classic.SessionStart', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.UserPromptSubmit', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.PermissionRequest', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.PermissionDenied', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.Notification', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.Stop', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.StopFailure', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.CwdChanged', ($, e, next) => {
    void send($, e)
    return next(e)
  })
  on('classic.PostModelSwitch', async ($, e, next) => {
    void send($, e)
    const result = await next(e)
    void reportStatus($)
    return result
  })
  on('classic.SessionEnd', ($, e, next) => {
    void send($, e)
    return next(e)
  })

  // PreToolUse, from the tool call itself: the classic event's input here is the tool's arguments,
  // not the hook's payload, and Clinic wants only the name and whose loop it ran in.
  on('tool.call', async ($, e, next) => {
    void send($, { hook_event_name: 'PreToolUse', session_id: await $.session.id(), tool_name: e.tool, agent_id: e.agentId }, false)
    return next(e)
  })

  // Each model request of the main loop changes the context figure, and names the model and effort.
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (e.agentId === undefined) {
      effort = e.effort === undefined ? undefined : String(e.effort)
      void reportStatus($, e.model)
    }
    return result
  })

  // Why the main loop's turn ended. `answer` also fires Stop; `aborted` and `refusal` fire nothing else.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      void send($, { hook_event_name: 'TurnEnd', session_id: await $.session.id(), reason: e.reason, duration_ms: e.durationMs })
    }
    return next(e)
  })

  // Clinic waits for this after it sees the session start: without it the mod did not load, and
  // Clinic goes back to settings hooks for the sessions it launches next.
  on('session.start', async ($, e, next) => {
    const version = await $.session.version()
    void send($, { hook_event_name: 'ModAttached', session_id: await $.session.id(), cwd: e.cwd, cli_version: version.version })
    void reportStatus($)
    return next(e)
  })

  // The process is about to go: give what is queued a moment to leave, and no longer.
  on('session.end', async ($, e, next) => {
    try {
      await Promise.race([queue, $.clock.sleep(1000)])
    } catch {
      // Leaving anyway.
    }
    return next(e)
  })
}
