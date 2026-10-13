const { test } = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const vm = require('node:vm')
const source = readFileSync('app/javascript/theme.js', 'utf8')

function browser({ saved = null, dark = false, blocked = false } = {}) {
  const events = new Map()
  const attrs = {}
  const buttons = ['light', 'dark', 'system'].map(value => ({
    dataset: { themeValue: value },
    setAttribute(name, value) { this[name] = value }
  }))
  let stored = saved
  const listen = (name, handler) => {
    const handlers = events.get(name) || []
    handlers.push(handler)
    events.set(name, handlers)
  }
  const media = { matches: dark, addEventListener: (name, handler) => listen(`media:${name}`, handler) }
  const context = vm.createContext({
    window: { matchMedia: () => media, addEventListener: listen },
    document: {
      documentElement: { setAttribute: (name, value) => { attrs[name] = value } },
      querySelectorAll: () => buttons,
      addEventListener: listen
    },
    localStorage: {
      getItem() { if (blocked) throw Error('Storage blocked'); return stored },
      setItem(key, value) { if (blocked) throw Error('Storage blocked'); stored = value }
    }
  })
  const emit = (name, event = {}) => (events.get(name) || []).forEach(handler => handler(event))
  vm.runInContext(source, context)
  return {
    attrs, buttons, media, events, emit,
    select(value) { emit('click', { target: { closest: () => buttons.find(button => button.dataset.themeValue === value) } }) },
    reload() { return browser({ saved: stored, dark: media.matches, blocked }) },
    replaceBody() { buttons.forEach(button => { button['aria-pressed'] = 'false' }); emit('turbo:load') },
    runAgain() { vm.runInContext(source, context) },
    setStored(value) { stored = value }
  }
}

test('only light and dark are offered', () => {
  const page = browser()
  page.select('system')
  assert.equal(page.attrs['data-bs-theme'], 'light')
  assert.equal(page.buttons.find(button => button.dataset.themeValue === 'system')['aria-pressed'], 'false')
})

test('first visit starts from the OS appearance and highlights that choice', () => {
  const page = browser({ dark: true })
  assert.equal(page.attrs['data-bs-theme'], 'dark')
  assert.equal(page.buttons[1]['aria-pressed'], 'true')
})

test('explicit choice survives a full reload and ignores the OS appearance', () => {
  const page = browser({ dark: true })
  page.select('light')
  assert.equal(page.attrs['data-bs-theme'], 'light')
  assert.equal(page.reload().attrs['data-bs-theme'], 'light')
})

test('a previously saved system preference falls back to the OS appearance', () => {
  const page = browser({ saved: 'system', dark: true })
  assert.equal(page.attrs['data-theme-preference'], 'dark')
  assert.equal(page.attrs['data-bs-theme'], 'dark')
})

test('Turbo navigation restores control state and click handling works on the new body', () => {
  const page = browser({ saved: 'dark' })
  page.replaceBody()
  assert.equal(page.buttons[1]['aria-pressed'], 'true')
  page.select('light')
  assert.equal(page.attrs['data-bs-theme'], 'light')
  assert.equal(page.buttons[0]['aria-pressed'], 'true')
})

test('storage restrictions do not prevent theme changes or initial rendering', () => {
  const page = browser({ blocked: true, dark: true })
  assert.equal(page.attrs['data-bs-theme'], 'dark')
  page.select('light')
  assert.equal(page.attrs['data-bs-theme'], 'light')
})

test('invalid saved values fall back to the OS appearance', () => {
  const page = browser({ saved: 'invalid', dark: true })
  assert.equal(page.attrs['data-theme-preference'], 'dark')
  assert.equal(page.attrs['data-bs-theme'], 'dark')
})

test('other tabs and clearing storage refresh the preference', () => {
  const page = browser()
  page.setStored('dark')
  page.emit('storage', { key: 'hellosmc-theme' })
  assert.equal(page.attrs['data-bs-theme'], 'dark')
  page.setStored(null)
  page.emit('storage', { key: null })
  assert.equal(page.attrs['data-bs-theme'], 'light')
})

test('reevaluating the asset does not register duplicate event handlers', () => {
  const page = browser()
  page.runAgain()
  assert.equal(page.events.get('click').length, 1)
  page.select('dark')
  assert.equal(page.attrs['data-bs-theme'], 'dark')
})
