const { test } = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const vm = require('node:vm')

function controller(name, globals = {}) {
  const source = readFileSync(`app/javascript/controllers/${name}_controller.js`, 'utf8')
    .replace(/^import .*\n/gm, '').replace('export default class', 'module.exports = class')
  const context = { Controller: class {}, module: {}, ...globals }
  vm.runInNewContext(source, context)
  return new context.module.exports()
}

function thread(history = false) {
  const callbacks = []
  const view = controller('chat_thread', {
    requestAnimationFrame: callback => { callbacks.push(callback); return 1 },
    cancelAnimationFrame: () => {}
  })
  view.historyValue = history
  view.logTarget = {
    scrollTop: 0, scrollHeight: 1200, clientHeight: 400,
    scrollTo({ top }) { this.scrollTop = Math.min(top, this.scrollHeight - this.clientHeight) }
  }
  view.latestTarget = { hidden: true }
  view.connect()
  callbacks.forEach(callback => callback())
  return view
}

test('opening old history preserves the reading position and offers a return to the bottom', () => {
  const view = thread(true)
  assert.equal(view.logTarget.scrollTop, 0)
  assert.equal(view.latestTarget.hidden, false)
  view.jump()
  assert.equal(view.logTarget.scrollTop, 800)
  assert.equal(view.latestTarget.hidden, true)
})

test('photos loading do not pull a reader away from older messages', () => {
  const view = thread()
  view.logTarget.scrollTop = 200
  view.scrolled()
  view.logTarget.scrollHeight = 1600
  view.imageLoaded()
  assert.equal(view.logTarget.scrollTop, 200)
  assert.equal(view.latestTarget.hidden, false)
})

test('a reader following the latest message stays at the bottom when photos load', () => {
  const view = thread()
  assert.equal(view.latestTarget.hidden, true)
  view.logTarget.scrollHeight = 1600
  view.imageLoaded()
  assert.equal(view.logTarget.scrollTop, 1600)
})

test('conversation info exposes its state and restores focus on close', () => {
  const view = controller('chat_workspace')
  let closeFocus = 0
  let toggleFocus = 0
  const attrs = {}
  view.hasInfoTarget = true
  view.infoTarget = { hidden: true, querySelector: () => ({ focus: () => closeFocus++ }) }
  view.infoToggleTarget = { setAttribute: (key, value) => { attrs[key] = value }, focus: () => toggleFocus++ }
  view.toggleInfo()
  assert.equal(view.infoTarget.hidden, false)
  assert.equal(attrs['aria-expanded'], 'true')
  assert.equal(closeFocus, 1)
  view.closeInfo()
  assert.equal(view.infoTarget.hidden, true)
  assert.equal(attrs['aria-expanded'], 'false')
  assert.equal(toggleFocus, 1)
})
