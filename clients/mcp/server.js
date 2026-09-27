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

const TOOLS = [
  { name: 'doctor', desc: 'Which capabilities are permitted right now.', args: {} },
  { name: 'apps', desc: 'Running applications that have windows.', args: {} },
  { name: 'window', desc: 'Live window rect for an app. Never cached.', args: { app: 'string' } },
  { name: 'front', desc: 'Which app is frontmost now, and the origin restore will return to.', args: {} },
  { name: 'focus', desc: 'Bring an app to the front and stop.', args: { app: 'string' } },
  { name: 'restore', desc: 'Last step of every run: bring back the app that was in front before the first focus change. forget clears the record without moving focus.', args: { forget: 'boolean?' } },
  { name: 'launch', desc: 'Launch an app and wait for its window.', args: { app: 'string' } },
  { name: 'navigate', desc: 'Open a URL in a browser and return when the page has loaded. Reliable — do not type URLs by keystroke.', args: { app: 'string', url: 'string', timeout: 'number?' } },
  { name: 'wait_idle', desc: "Return the instant an app's text stops changing, after a click or load. Use instead of a fixed sleep.", args: { app: 'string', timeout: 'number?' } },
  { name: 'text', desc: "An app's text via accessibility: fast, verbatim, whole page in one call. PREFER this for reading content; OCR (read/find) is the fallback.", args: { app: 'string' } },
  { name: 'read', desc: 'OCR: every text line with a click POINT. For reading content prefer text; use read/find to locate something to click.', args: { app: 'string' } },
  { name: 'find', desc: 'Where a piece of text is on screen (OCR, returns a click point).', args: { app: 'string', text: 'string' } },
  { name: 'controls', desc: 'List an app\'s actionable controls by name via accessibility. The accessibility answer to read.', args: { app: 'string' } },
  { name: 'activate', desc: 'Press a control by name via accessibility. Works where posted clicks are swallowed (modal sheets, popups).', args: { app: 'string', control: 'string' } },
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
  properties: Object.fromEntries(Object.entries(args).map(([k, t]) => [k, { type: t.replace('?', '') }])),
  required: Object.keys(args).filter((k) => !args[k].endsWith('?')),
})

function argvFor(name, a = {}) {
  switch (name) {
    case 'window': case 'launch': case 'read': case 'apps': case 'doctor':
    case 'text': case 'controls': case 'focus': case 'front':
      return [name.replace('_', '-'), a.app].filter(Boolean)
    case 'restore': return ['restore', ...(a.forget ? ['--forget'] : [])]
    case 'find': return ['find', a.app, a.text]
    case 'navigate': return ['navigate', a.app, a.url, '--timeout', a.timeout ?? 15]
    case 'wait_idle': return ['wait-idle', a.app, '--timeout', a.timeout ?? 10]
    case 'activate': return ['activate', a.app, a.control]
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
