/** Real subprocess boundary tests; PATH points only to our isolated fake CLI first. */
import assert from 'node:assert/strict'
import { afterEach, beforeEach, test } from 'node:test'
import { chmodSync, copyFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as macctl from '../../clients/typescript/macctl.ts'

let directory
let previousEnvironment
beforeEach(() => {
  previousEnvironment = Object.fromEntries(['PATH', 'MACCTL_TEST_RESPONSE', 'MACCTL_TEST_ARGV_FILE'].map(key => [key, process.env[key]]))
  directory = mkdtempSync(join(tmpdir(), 'macctl-typescript-client-'))
  const fake = join(directory, 'macctl')
  copyFileSync(fileURLToPath(new URL('./fixtures/macctl', import.meta.url)), fake)
  chmodSync(fake, 0o755)
  process.env.PATH = directory + delimiter + (process.env.PATH ?? '')
  process.env.MACCTL_TEST_ARGV_FILE = join(directory, 'argv.json')
  respond(0, {})
})
afterEach(() => {
  for (const [key, value] of Object.entries(previousEnvironment)) {
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
  rmSync(directory, { recursive: true, force: true })
})
function respond(code, data, extra = {}) {
  process.env.MACCTL_TEST_RESPONSE = JSON.stringify({ code, ...(data === undefined ? {} : { data }), ...extra })
}
const helpers = {
  read: () => macctl.read('Example App'),
  text: () => macctl.text('Example App'),
  controls: () => macctl.controls('Example App'),
  browser: () => macctl.browser('Example App'),
  front: () => macctl.front()
}

test('successful empty observations keep their return types', () => {
  respond(0, { lines: [], text: '', controls: [], front: null })
  for (const [name, expected] of [['read', []], ['text', ''], ['controls', []], ['front', null]]) {
    assert.deepEqual(helpers[name](), expected, name)
  }
})
test('successful nonempty observations preserve their payloads', () => {
  const payload = { lines: [{ text: 'Hello', at: [.2, .3] }], text: 'Hello\nWorld',
    controls: [{ role: 'AXButton', label: 'Open', at: [.1, .2] }], front: { name: 'Example App', pid: 123 } }
  respond(0, payload)
  for (const [name, field] of [['read', 'lines'], ['text', 'text'], ['controls', 'controls'], ['front', 'front']]) {
    assert.deepEqual(helpers[name](), payload[field], name)
  }
})
test('browser returns the native snapshot with explicit null evidence', () => {
  const payload = { ok: true, readAt: '2026-10-02T18:00:00Z', app: 'Safari', pid: 123,
    source: 'accessibility', window: { title: 'Example', identifier: null, source: 'AXFocusedWindow' },
    page: { url: 'https://example.com', title: 'Example', loaded: null, loadingProgress: null,
      busy: null, source: 'AXWebArea.AXURL', reason: null },
    address: { value: 'example.com', focused: false, source: 'AXTextField.WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD' },
    tabs: [{ title: 'Example', selected: true, identifier: null, index: null }], complete: true }
  respond(0, payload)
  assert.deepEqual(macctl.browser('Safari'), payload)
  assert.deepEqual(argv(), ['browser', '--', 'Safari'])
})
test('controls preserve native attributes including nullable values and screen-point bounds', () => {
  const control = { role: 'AXTextField', label: 'Name', value: null, identifier: 'name-field',
    url: null, placeholder: 'Enter name', at: [200, 150], bounds: [100, 125, 200, 50],
    focused: null, enabled: true, pressable: false, valueSettable: true, secure: false }
  respond(0, { controls: [control] })
  assert.deepEqual(macctl.controls('Example App'), [control])
})
test('unknown is never an empty or partial observation', () => {
  for (const payload of [
    { outcome: 'unknown: capture failed' },
    { outcome: 'unknown: capture failed', lines: [], text: '', controls: [], front: null },
    { outcome: 'unknown: incomplete capture', lines: [{ text: 'Partial' }], text: 'Partial',
      controls: [{ label: 'Partial' }], front: { name: 'Partial' } }
  ]) {
    respond(2, payload)
    for (const [name, call] of Object.entries(helpers)) {
      assert.throws(call, error => {
        assert.ok(error instanceof macctl.ObservationUnknown, name)
        assert.ok(!(error instanceof macctl.Refused), name)
        assert.equal(error.result.code, 2)
        assert.equal(error.result.unknown, true)
        assert.deepEqual(error.result.data, payload)
        assert.equal(error.message, payload.outcome)
        return true
      })
    }
  }
})
test('unknown without JSON preserves the stderr reason', () => {
  respond(2, undefined, { stdout: '', stderr: 'capture watchdog expired\n' })
  for (const call of Object.values(helpers)) {
    assert.throws(call, error => {
      assert.ok(error instanceof macctl.ObservationUnknown)
      assert.deepEqual(error.result.data, {})
      assert.equal(error.result.reason, 'capture watchdog expired')
      return true
    })
  }
})
test('refusals remain distinct for every observation helper', () => {
  for (const code of [3, 4]) {
    for (const response of [{ data: { outcome: 'refused: unavailable' } }, { stdout: '', stderr: 'permission missing' }]) {
      respond(code, undefined, response)
      for (const call of Object.values(helpers)) assert.throws(call, macctl.Refused)
    }
  }
})
test('unsatisfied payloads are not unwrapped as observations', () => {
  respond(1, { outcome: 'unsatisfied', text: '', lines: [] })
  for (const call of Object.values(helpers)) {
    assert.throws(call, error => {
      assert.ok(error instanceof macctl.ObservationError)
      assert.ok(!(error instanceof macctl.ObservationUnknown))
      assert.equal(error.result.code, 1)
      return true
    })
  }
})
test('Result-returning helpers retain unknown without throwing', () => {
  respond(2, { outcome: 'unknown: not observable', verified: false })
  const calls = [() => macctl.run('read', 'Example App'), () => macctl.window('Example App'),
    () => macctl.click('Example App', .2, .3), () => macctl.drag('Example App', .1, .2, .3, .4),
    () => macctl.clickText('Example App', 'Open'), () => macctl.verify('Example App', 'Saved'),
    () => macctl.waitFor('Example App', 'Saved'), () => macctl.navigate('Example App', 'about:blank'),
    () => macctl.waitIdle('Example App'), () => macctl.activate('Example App', 'Open'),
    () => macctl.setValue('Example App', 'Example', { identifier: 'name' }),
    () => macctl.choose('Example App', 'Off', 'On'), () => macctl.focus('Example App'), () => macctl.restore()]
  for (const call of calls) {
    const result = call()
    assert.equal(result.code, 2)
    assert.equal(result.unknown, true)
    assert.equal(result.satisfied, false)
  }
  respond(1, { outcome: 'unsatisfied' })
  assert.equal(macctl.verify('Example App', 'Saved').unknown, false)
  respond(3, { outcome: 'refused: permission missing' })
  assert.throws(() => macctl.run('doctor'), macctl.Refused)
})
test('subprocess arguments remain literal', () => {
  respond(0, { text: 'literal' })
  const app = 'Example App ; $(not-a-command)'
  assert.equal(macctl.text(app), 'literal')
  assert.deepEqual(JSON.parse(readFileSync(process.env.MACCTL_TEST_ARGV_FILE, 'utf8')), ['text', app])
})
test('failure to launch the CLI cannot become an unsatisfied observation', () => {
  rmSync(join(directory, 'macctl'))
  process.env.PATH = directory
  assert.throws(() => macctl.run('read', 'Example App'), error => error.code === 'ENOENT')
  assert.throws(() => macctl.read('Example App'), error => error.code === 'ENOENT')
})

function argv() { return JSON.parse(readFileSync(process.env.MACCTL_TEST_ARGV_FILE, 'utf8')) }

test('selectors and literal positionals reach the CLI', () => {
  const options = { scope: 'window', role: 'AXTextField', identifier: 'field.id',
    match: '--literal ; $(not-a-command)', exact: true }
  const flags = ['--scope', 'window', '--role', 'AXTextField', '--identifier', 'field.id',
    '--match', options.match, '--exact']
  const app = '--Example App'
  respond(0, { controls: [] })
  macctl.controls(app, options)
  assert.deepEqual(argv(), ['controls', ...flags, '--', app])
  macctl.activate(app, options)
  assert.deepEqual(argv(), ['activate', ...flags, '--', app])
  macctl.activate(app, '--Open', options)
  assert.deepEqual(argv(), ['activate', ...flags, '--', app, '--Open'])
  const value = '--value\n\'"` $(not-a-command)'
  macctl.setValue(app, value, options)
  assert.deepEqual(argv(), ['set-value', ...flags, '--', app, value])
  macctl.browser(app)
  assert.deepEqual(argv(), ['browser', '--', app])
})
test('existing calls and empty values are preserved', () => {
  respond(0, { controls: [] })
  macctl.controls('Example App')
  assert.deepEqual(argv(), ['controls', '--', 'Example App'])
  macctl.activate('Example App', 'Open')
  assert.deepEqual(argv(), ['activate', '--', 'Example App', 'Open'])
  macctl.setValue('Example App', '', { match: '', exact: false })
  assert.deepEqual(argv(), ['set-value', '--match', '', '--', 'Example App', ''])
})
test('setValue retains observed mismatch and unknown readback', () => {
  for (const [code, after, verified] of [[0, 'new', true], [1, 'old', false], [2, null, null]]) {
    const payload = { before: 'old', after, verified }
    respond(code, payload)
    const result = macctl.setValue('Example App', 'new', { identifier: 'name' })
    assert.equal(result.code, code)
    assert.equal(result.satisfied, code === 0)
    assert.equal(result.unknown, code === 2)
    assert.deepEqual(result.data, payload)
  }
  for (const code of [3, 4]) {
    respond(code, { outcome: 'refused: unavailable' })
    assert.throws(() => macctl.setValue('Example App', 'new', { identifier: 'name' }), macctl.Refused)
  }
})
