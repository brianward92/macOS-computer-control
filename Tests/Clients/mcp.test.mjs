/** Exercise the stdio MCP server against a subprocess fixture, never the real CLI. */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { afterEach, beforeEach, test } from 'node:test'
import { chmodSync, copyFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { fileURLToPath } from 'node:url'

let directory
let environment
const server = fileURLToPath(new URL('../../clients/mcp/server.js', import.meta.url))
beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), 'macctl-mcp-client-'))
  const fake = join(directory, 'macctl')
  copyFileSync(fileURLToPath(new URL('./fixtures/macctl', import.meta.url)), fake)
  chmodSync(fake, 0o755)
  environment = { ...process.env, PATH: directory + delimiter + (process.env.PATH ?? ''),
    MACCTL_TEST_ARGV_FILE: join(directory, 'argv.json'),
    MACCTL_TEST_RESPONSE: JSON.stringify({ code: 0, data: {} }) }
})
afterEach(() => rmSync(directory, { recursive: true, force: true }))

function request(method, params = {}) {
  const stdout = execFileSync(process.execPath, [server], {
    encoding: 'utf8', env: environment, timeout: 5000,
    input: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) + '\n',
  })
  return JSON.parse(stdout.trim()).result
}
function call(name, args = {}) {
  const result = request('tools/call', { name, arguments: args })
  return { data: JSON.parse(result.content[0].text), isError: result.isError }
}
function argv() { return JSON.parse(readFileSync(environment.MACCTL_TEST_ARGV_FILE, 'utf8')) }

test('MCP exposes browser and set_value with shared selector schemas', () => {
  const tools = Object.fromEntries(request('tools/list').tools.map(tool => [tool.name, tool]))
  assert.deepEqual(tools.browser.inputSchema.required, ['app'])
  assert.deepEqual(tools.set_value.inputSchema.required, ['app', 'value'])
  assert.deepEqual(tools.activate.inputSchema.required, ['app'])
  assert.equal(tools.activate.inputSchema.properties.control.type, 'string')
  for (const name of ['controls', 'activate', 'set_value']) {
    const properties = tools[name].inputSchema.properties
    assert.deepEqual(properties.scope, { type: 'string', enum: ['app', 'window'], default: 'app' })
    for (const key of ['role', 'identifier', 'match']) assert.equal(properties[key].type, 'string')
    assert.equal(properties.exact.type, 'boolean')
  }
})

test('MCP forwards selectors and protects literal positionals', () => {
  const selectors = { scope: 'window', role: 'AXTextField', identifier: 'field.id',
    match: '--literal ; $(not-a-command)', exact: true }
  const flags = ['--scope', 'window', '--role', 'AXTextField', '--identifier', 'field.id',
    '--match', selectors.match, '--exact']
  const app = '--Example App'
  call('browser', { app })
  assert.deepEqual(argv(), ['browser', '--', app])
  call('controls', { app, ...selectors })
  assert.deepEqual(argv(), ['controls', ...flags, '--', app])
  call('activate', { app, ...selectors })
  assert.deepEqual(argv(), ['activate', ...flags, '--', app])
  call('activate', { app, control: '--Open', ...selectors })
  assert.deepEqual(argv(), ['activate', ...flags, '--', app, '--Open'])
  const value = '--value\n\'"` $(not-a-command)'
  call('set_value', { app, value, ...selectors })
  assert.deepEqual(argv(), ['set-value', ...flags, '--', app, value])
})

test('MCP preserves old calls and empty values without inventing selector defaults', () => {
  call('controls', { app: 'Example App' })
  assert.deepEqual(argv(), ['controls', '--', 'Example App'])
  call('activate', { app: 'Example App', control: 'Open' })
  assert.deepEqual(argv(), ['activate', '--', 'Example App', 'Open'])
  call('set_value', { app: 'Example App', value: '', match: '', exact: false })
  assert.deepEqual(argv(), ['set-value', '--match', '', '--', 'Example App', ''])
})

test('MCP browser preserves the full snapshot including partial unknown observations', () => {
  const snapshot = { ok: true, readAt: '2026-10-02T18:00:00Z', app: 'Safari', pid: 123,
    window: { title: 'Example' }, page: { url: 'https://example.com' }, address: null,
    tabs: [{ title: 'Example', selected: true }], complete: false }
  for (const [code, outcome] of [[0, 'satisfied'], [2, 'unknown']]) {
    environment.MACCTL_TEST_RESPONSE = JSON.stringify({ code, data: snapshot })
    assert.deepEqual(call('browser', { app: 'Safari' }), {
      data: { outcome, exitCode: code, ...snapshot }, isError: false,
    })
  }
})

test('MCP set_value preserves exact readback, mismatch, unknown and refusal', () => {
  for (const [code, outcome, after, verified] of [
    [0, 'satisfied', 'new', true], [1, 'unsatisfied', 'old', false],
    [2, 'unknown', null, null], [3, 'refused', null, null], [4, 'refused', null, null],
  ]) {
    const payload = { before: 'old', after, verified }
    environment.MACCTL_TEST_RESPONSE = JSON.stringify({ code, data: payload })
    assert.deepEqual(call('set_value', { app: 'Example App', value: 'new', identifier: 'name' }), {
      data: { outcome, exitCode: code, ...payload }, isError: code === 3 || code === 4,
    })
  }
})
