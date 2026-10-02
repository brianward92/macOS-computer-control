/**
 * Intentionally partial TypeScript wrapper over the macctl CLI.
 *
 * The CLI is the contract; this only saves subprocess boilerplate. Exit codes
 * are preserved because they carry meaning the JSON does not: 2 means "could
 * not observe", which is not the same as failure. Payload-unwrapping helpers
 * throw ObservationUnknown for exit 2; empty payloads still mean a successful
 * observation of no content.
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

/** An observation helper could not return a successful payload. */
export class ObservationError extends Error {
  readonly result: Result
  constructor(result: Result) {
    super(result.reason ?? `macctl observation exited ${result.code}`)
    this.name = new.target.name
    this.result = result
  }
}

/** Exit 2: could not observe, or invalid usage; not evidence of absence. */
export class ObservationUnknown extends ObservationError {}

export function run(...args: (string | number)[]): Result {
  let stdout = ''
  let stderr = ''
  let code = 0
  try {
    stdout = execFileSync('macctl', args.map(String), { encoding: 'utf8', stdio: 'pipe' })
  } catch (err) {
    const e = err as { status?: number; stdout?: string; stderr?: string }
    // A launch failure or killed process is not an observed, unsatisfied result.
    if (typeof e.status !== 'number') throw err
    code = e.status
    stdout = e.stdout ?? ''
    stderr = e.stderr ?? ''
  }
  const lines = stdout.trim().split('\n').filter(Boolean)
  const data = lines.length ? (JSON.parse(lines[lines.length - 1]) as Record<string, unknown>) : {}
  const reason = (data.outcome as string) ?? (data.error as string) ?? (stderr.trim() || undefined)
  if (code === 3 || code === 4) throw new Refused(reason ?? `macctl exited ${code}`)
  return { code, data, satisfied: code === 0, unknown: code === 2, reason }
}

function observation(...args: (string | number)[]): Record<string, unknown> {
  const result = run(...args)
  if (result.unknown) throw new ObservationUnknown(result)
  if (!result.satisfied) throw new ObservationError(result)
  return result.data
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
/** OCR lines; throws ObservationUnknown when the screen could not be read. */
export const read = (app: string) =>
  observation('read', app).lines as { text: string; at: [number, number] }[]

/** The app's text via accessibility, OCR as fallback. Prefer over read for content. */
export const text = (app: string) => (observation('text', app).text as string) ?? ''
/**
 * Ask the browser to open a URL, then wait for observed text to settle.
 * Its external-open policy may create a tab. Settled text is not proof of
 * page readiness; verify the intended page state.
 */
export const navigate = (app: string, url: string, timeout = 15) =>
  run('navigate', app, url, '--timeout', timeout)
/** Return the instant the app's text stops changing, instead of a fixed sleep. */
export const waitIdle = (app: string, timeout = 10) => run('wait-idle', app, '--timeout', timeout)

export interface BrowserWindow {
  identifier: string | null
  title: string | null
  /** AX attribute used to select the observed window. */
  source: string
}

export interface BrowserPage {
  /** Committed document URL, separate from any address-bar edit. */
  url: string | null
  title: string | null
  /** Null means the browser did not expose this loading signal. */
  loaded: boolean | null
  loadingProgress: number | null
  busy: boolean | null
  source: string | null
  /** Why committed document evidence could not be established, when applicable. */
  reason: string | null
}

export interface BrowserAddress {
  /** Address-bar text may be an uncommitted edit, not the document URL. */
  value: string | null
  focused: boolean | null
  source: string | null
}

export interface BrowserTab {
  index: number | null
  title: string | null
  selected: boolean | null
  /** Observed AX identifier, not a durable tab handle. */
  identifier: string | null
}

export interface BrowserSnapshot extends Record<string, unknown> {
  ok: boolean
  readAt: string
  app: string
  pid: number
  source: 'accessibility'
  window: BrowserWindow
  page: BrowserPage
  address: BrowserAddress
  tabs: BrowserTab[]
  complete: boolean
  outcome?: string
}

/** Full successful browser AX snapshot, including page, address and exposed tabs.
 * Check `complete` before treating omitted information as absent.
 */
export const browser = (app: string): BrowserSnapshot =>
  observation('browser', '--', app) as BrowserSnapshot

/** Native AX control evidence. Null means the attribute was not exposed. */
export interface Control {
  role: string
  label: string
  value: string | null
  identifier: string | null
  url: string | null
  placeholder: string | null
  /** Screen points, top-left origin; not window-relative fractions. */
  at: [number, number]
  /** Screen-point x, y, width, height, or null if unavailable. */
  bounds: [number, number, number, number] | null
  focused: boolean | null
  enabled: boolean
  pressable: boolean
  valueSettable: boolean
  secure: boolean
}

export interface ControlSelector {
  /** `app` is the CLI default; `window` limits the search to the front window. */
  scope?: 'app' | 'window'
  role?: string
  identifier?: string
  match?: string
  /** Match the whole label instead of a substring. */
  exact?: boolean
}

function selectorArgs(options: ControlSelector): string[] {
  const args: string[] = []
  for (const name of ['scope', 'role', 'identifier', 'match'] as const) {
    const value = options[name]
    if (value !== undefined) args.push(`--${name}`, value)
  }
  if (options.exact) args.push('--exact')
  return args
}

/** Accessible controls filtered by label, role or identifier. Selectors combine. */
export const controls = (app: string, options: ControlSelector = {}): Control[] =>
  observation('controls', ...selectorArgs(options), '--', app).controls as Control[]

/** Press one accessible control by name or selectors; refuse ambiguity.
 * Verify the effect afterwards; delivery alone does not establish app state.
 */
export function activate(app: string, control: string, options?: ControlSelector): Result
export function activate(app: string, options: ControlSelector): Result
export function activate(app: string, controlOrOptions: string | ControlSelector,
                         options: ControlSelector = {}): Result {
  const positional = typeof controlOrOptions === 'string' ? [app, controlOrOptions] : [app]
  const selectors = typeof controlOrOptions === 'string' ? options : controlOrOptions
  return run('activate', ...selectorArgs(selectors), '--', ...positional)
}

/** Set a selected control's native AX value and return before/after/verified.
 * Exit 0 is exact readback, 1 observed mismatch, 2 unknown. This does not submit
 * a form or establish any later application effect.
 */
export const setValue = (app: string, value: string, options: ControlSelector) =>
  run('set-value', ...selectorArgs(options), '--', app, value)
/** Set a popup menu to a value via accessibility; the result carries before/after. */
export const choose = (app: string, popup: string, value: string) => run('choose', app, popup, value)
/** The frontmost app right now. */
export const front = () => observation('front').front as { name: string; pid: number; bundleID?: string } | null
/** Bring an app to the front and stop. */
export const focus = (app: string) => run('focus', app)
/**
 * Put the person back where they were before the first focus change. `forget`
 * clears the record without moving focus, for a task meant to land them elsewhere.
 */
export const restore = (forget = false) => run('restore', ...(forget ? ['--forget'] : []))
