#!/usr/bin/env node
/**
 * MCP server over the macctl CLI — stdio, no dependencies.
 *
 * Deliberately partial and thin. The CLI is the complete contract; this
 * only exposes it as typed tools for harnesses that speak MCP. Anything that
 * needs to change should change in the CLI, not here.
 *
 * The one thing it must not lose in translation is the ternary outcome: exit
 * code 2 means "could not observe", which is not failure. It is reported as
 * `outcome: "unknown"` with the reason, never as an error.
 */
const { execFile } = require('node:child_process')

const SELECTORS = { scope: 'string?', role: 'string?', identifier: 'string?', match: 'string?', exact: 'boolean?' }

const TOOLS = [
  { name: 'doctor', desc: 'Which capabilities are permitted right now.', args: {} },
  { name: 'apps', desc: 'Running applications that have windows.', args: {} },
  { name: 'window', desc: 'Live window rect for an app. Never cached.', args: { app: 'string' } },
  { name: 'front', desc: 'Which app is frontmost now, and the origin restore will return to.', args: {} },
  { name: 'focus', desc: 'Bring an app to the front and stop.', args: { app: 'string' } },
  { name: 'restore', desc: 'Last step of every run: bring back the app that was in front before the first focus change. forget clears the record without moving focus.', args: { forget: 'boolean?' } },
  { name: 'launch', desc: 'Launch an app and wait for its window.', args: { app: 'string' } },
  { name: 'navigate', desc: 'Ask the browser to open a URL, then wait for observed text to settle. External-open policy may create a tab. Settled text is not proof of page readiness; verify the intended page state.', args: { app: 'string', url: 'string', timeout: 'number?' } },
  { name: 'browser', desc: 'Read a browser AX snapshot: app, window, page, address and exposed tabs. Check complete before treating omitted information as absent. Does not run browser scripts.', args: { app: 'string' } },
  { name: 'wait_idle', desc: "Return the instant an app's text stops changing, after a click or load. Use instead of a fixed sleep.", args: { app: 'string', timeout: 'number?' } },
  { name: 'text', desc: "An app's text via accessibility: fast, verbatim, whole page in one call. PREFER this for reading content; OCR (read/find) is the fallback.", args: { app: 'string' } },
  { name: 'read', desc: 'OCR: every text line with a click POINT. For reading content prefer text; use read/find to locate something to click.', args: { app: 'string' } },
  { name: 'find', desc: 'Where a piece of text is on screen (OCR, returns a click point).', args: { app: 'string', text: 'string' } },
  { name: 'controls', desc: 'Read accessible controls, optionally filtered by role, identifier or label match. Selectors combine. scope defaults to app; window limits to the front window. exact matches the whole label.', args: { app: 'string', ...SELECTORS } },
  { name: 'activate', desc: 'Press one accessible control selected by the positional control label or selectors. Refuses ambiguous targets. scope defaults to app. Delivery does not verify the resulting app state.', args: { app: 'string', control: 'string?', ...SELECTORS } },
  { name: 'set_value', desc: 'Set one selected control\'s native AX value and read it back. Select by match, role or identifier. Returns before/after and verified: true (exit 0 exact readback), false (exit 1 observed mismatch), or null (exit 2 unknown). Does not submit a form.', args: { app: 'string', value: 'string', ...SELECTORS } },
  { name: 'choose', desc: 'Set a popup menu to a value via accessibility; reports before/after so it self-verifies.', args: { app: 'string', popup: 'string', value: 'string' } },
  {
    name: 'click',
    desc: 'Click at a FRACTION of the window. Returns verified:false — delivery is not proof it landed.',
    args: { app: 'string', fx: 'number', fy: 'number', count: 'number?' },
  },
  {
    name: 'drag',
    desc: 'Press, move with intermediate motion, release. Many UIs need this where a click only previews.',
    args: { app: 'string', fx1: 'number', fy1: 'number', fx2: 'number', fy2: 'number' },
  },
  { name: 'scroll', desc: 'Scroll at a fraction of the window. Negative amount scrolls down. Follow with wait_idle after content loads.', args: { app: 'string', fx: 'number', fy: 'number', amount: 'number' } },
  { name: 'click_text', desc: 'Find text, refuse if ambiguous, then click it. timeout (seconds) keeps looking; 0 is a single look, and a single miss is unknown, not absent.', args: { app: 'string', text: 'string', timeout: 'number?' } },
  { name: 'verify', desc: 'Is this text on screen? satisfied / unsatisfied / unknown.', args: { app: 'string', text: 'string' } },
  { name: 'wait_for', desc: 'Wait for text to appear, or with gone:true to disappear (confirm a sheet closed).', args: { app: 'string', text: 'string', timeout: 'number?', gone: 'boolean?' } },
  { name: 'key', desc: 'Press a chord such as cmd+q. Give app, or it goes to whatever is in front.', args: { chord: 'string', app: 'string?' } },
  { name: 'type', desc: 'Type literal text. Give app, or it goes to whatever is in front.', args: { text: 'string', app: 'string?' } },
]

// A type ending in '?' is optional.
const schema = (args) => ({
  type: 'object',
  properties: Object.fromEntries(Object.entries(args).map(([k, t]) => [k, {
    type: t.replace('?', ''), ...(k === 'scope' ? { enum: ['app', 'window'], default: 'app' } : {}),
  }])),
  required: Object.keys(args).filter((k) => !args[k].endsWith('?')),
})

function selectorArgs(a) {
  const args = []
  for (const name of ['scope', 'role', 'identifier', 'match']) {
    if (a[name] !== undefined) args.push(`--${name}`, a[name])
  }
  if (a.exact) args.push('--exact')
  return args
}

function argvFor(name, a = {}) {
  switch (name) {
    case 'window': case 'launch': case 'read': case 'apps': case 'doctor':
    case 'text': case 'focus': case 'front':
      return [name.replace('_', '-'), a.app].filter(Boolean)
    case 'restore': return ['restore', ...(a.forget ? ['--forget'] : [])]
    case 'find': return ['find', a.app, a.text]
    case 'navigate': return ['navigate', a.app, a.url, '--timeout', a.timeout ?? 15]
    case 'wait_idle': return ['wait-idle', a.app, '--timeout', a.timeout ?? 10]
    case 'browser': return ['browser', '--', a.app]
    case 'controls': return ['controls', ...selectorArgs(a), '--', a.app]
    case 'activate': return ['activate', ...selectorArgs(a), '--', a.app, ...(a.control === undefined ? [] : [a.control])]
    case 'set_value': return ['set-value', ...selectorArgs(a), '--', a.app, a.value]
    case 'choose': return ['choose', a.app, a.popup, a.value]
    case 'click': return ['click', a.app, a.fx, a.fy, '--count', a.count ?? 1]
    case 'scroll': return ['scroll', a.app, a.fx, a.fy, a.amount]
    case 'drag': return ['drag', a.app, a.fx1, a.fy1, a.fx2, a.fy2]
    case 'click_text': return ['click-text', a.app, a.text, '--timeout', a.timeout ?? 0]
    case 'verify': return ['verify', a.app, a.text]
    case 'wait_for': return ['wait-for', a.app, a.text, '--timeout', a.timeout ?? 30, ...(a.gone ? ['--gone'] : [])]
    case 'key': return ['key', a.chord, ...(a.app ? ['--app', a.app] : [])]
    // --app must come before the text: everything after it is typed.
    case 'type': return ['type', ...(a.app ? ['--app', a.app] : []), a.text]
    default: throw new Error(`unknown tool: ${name}`)
  }
}

const OUTCOME = { 0: 'satisfied', 1: 'unsatisfied', 2: 'unknown', 3: 'refused', 4: 'refused' }

function call(name, a) {
  return new Promise((resolve) => {
    execFile('macctl', argvFor(name, a).map(String), (err, stdout) => {
      // err.code is the exit status when macctl ran, and a string such as
      // ENOENT when it could not be started at all. The latter is "could not
      // observe", not a result.
      const code = typeof err?.code === 'number' ? err.code : err ? 2 : 0
      const lines = String(stdout ?? '').trim().split('\n').filter(Boolean)
      let data = {}
      try { data = JSON.parse(lines[lines.length - 1] ?? '{}') } catch {}
      if (err && typeof err.code !== 'number') data = { ok: false, error: `could not run macctl: ${err.message}`, ...data }
      resolve({ outcome: OUTCOME[code] ?? 'unknown', exitCode: code, ...data })
    })
  })
}

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n') }

let buffer = ''
process.stdin.on('data', async (chunk) => {
  buffer += chunk
  const lines = buffer.split('\n')
  buffer = lines.pop() ?? ''
  for (const line of lines) {
    if (!line.trim()) continue
    let req
    try { req = JSON.parse(line) } catch { continue }

    if (req.method === 'initialize') {
      send({ jsonrpc: '2.0', id: req.id, result: {
        protocolVersion: '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'macctl', version: '0.1.0' },
      }})
    } else if (req.method === 'tools/list') {
      send({ jsonrpc: '2.0', id: req.id, result: {
        tools: TOOLS.map((t) => ({ name: t.name, description: t.desc, inputSchema: schema(t.args) })),
      }})
    } else if (req.method === 'tools/call') {
      const result = await call(req.params.name, req.params.arguments ?? {})
      send({ jsonrpc: '2.0', id: req.id, result: {
        content: [{ type: 'text', text: JSON.stringify(result) }],
        isError: result.exitCode === 3 || result.exitCode === 4,
      }})
    } else if (req.id !== undefined) {
      send({ jsonrpc: '2.0', id: req.id, error: { code: -32601, message: 'method not found' } })
    }
  }
})
