/**
 * Intentionally partial TypeScript wrapper over the macctl CLI.
 *
 * The CLI is the contract; this only saves subprocess boilerplate. Exit codes
 * are preserved because they carry meaning the JSON does not: 2 means "could
 * not observe", which is not the same as failure.
 */
import { execFileSync } from 'node:child_process'

export interface Result {
  code: number
  data: Record<string, unknown>
  /** Acted, observed, it happened. */
  satisfied: boolean
  /** Could not observe. Deliberately distinct from unsatisfied. */
  unknown: boolean
  reason?: string
}

export class Refused extends Error {}

export function run(...args: (string | number)[]): Result {
  let stdout = ''
  let code = 0
  try {
    stdout = execFileSync('macctl', args.map(String), { encoding: 'utf8' })
  } catch (err) {
    const e = err as { status?: number; stdout?: string; stderr?: string }
    code = e.status ?? 1
    stdout = e.stdout ?? ''
  }
  const lines = stdout.trim().split('\n').filter(Boolean)
  const data = lines.length ? (JSON.parse(lines[lines.length - 1]) as Record<string, unknown>) : {}
  const reason = (data.outcome as string) ?? (data.error as string) ?? undefined
  if (code === 3 || code === 4) throw new Refused(reason ?? `macctl exited ${code}`)
  return { code, data, satisfied: code === 0, unknown: code === 2, reason }
}

export const window = (app: string) => run('window', app)
export const click = (app: string, fx: number, fy: number, count = 1) =>
  run('click', app, fx, fy, '--count', count)
export const drag = (app: string, fx1: number, fy1: number, fx2: number, fy2: number) =>
  run('drag', app, fx1, fy1, fx2, fy2)
/** timeout 0 is a single look; a single miss is unknown, not absent. */
export const clickText = (app: string, text: string, timeout = 0) =>
  run('click-text', app, text, '--timeout', timeout)
export const verify = (app: string, text: string) => run('verify', app, text)
export const waitFor = (app: string, text: string, timeout = 30) =>
  run('wait-for', app, text, '--timeout', timeout)
export const read = (app: string) =>
  run('read', app).data.lines as { text: string; at: [number, number] }[]

/** The app's text via accessibility, OCR as fallback. Prefer over read for content. */
export const text = (app: string) => (run('text', app).data.text as string) ?? ''
/** Open a URL in a browser and return once the page has loaded. */
export const navigate = (app: string, url: string, timeout = 15) =>
  run('navigate', app, url, '--timeout', timeout)
/** Return the instant the app's text stops changing, instead of a fixed sleep. */
export const waitIdle = (app: string, timeout = 10) => run('wait-idle', app, '--timeout', timeout)
/** Actionable controls by name, via accessibility. */
export const controls = (app: string) =>
  run('controls', app).data.controls as { role: string; label: string; value?: string; at: [number, number] }[]
/** Press a control by name via accessibility. Works where posted clicks are swallowed. */
export const activate = (app: string, control: string) => run('activate', app, control)
/** Set a popup menu to a value via accessibility; the result carries before/after. */
export const choose = (app: string, popup: string, value: string) => run('choose', app, popup, value)
/** The frontmost app right now. */
export const front = () => run('front').data.front as { name: string; pid: number; bundleID?: string } | null
/** Bring an app to the front and stop. */
export const focus = (app: string) => run('focus', app)
/**
 * Put the person back where they were before the first focus change. `forget`
 * clears the record without moving focus, for a task meant to land them elsewhere.
 */
export const restore = (forget = false) => run('restore', ...(forget ? ['--forget'] : []))
