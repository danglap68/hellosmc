const { test } = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const vm = require('node:vm')
const jsQR = require('../../vendor/javascript/jsqr.js')
const fixtures = JSON.parse(readFileSync('spec/fixtures/qr/recipients.json', 'utf8'))
const source = readFileSync('app/javascript/controllers/bank_qr_upload_controller.js', 'utf8')
  .replace(/^import .*$/m, '')
  .replace('export default class', 'class BankQrUploadController')
const Controller = vm.runInNewContext(`${source}\nBankQrUploadController`, { Controller: class {}, window: { jsQR } })

// Rasterize real QR matrices, then use the vendored decoder on their pixels.
function canvas(codes) {
  const size = 400
  const width = size * codes.length
  const pixels = new Uint8ClampedArray(width * size * 4).fill(255)
  codes.forEach((code, index) => {
    const scale = Math.floor(size / (code.modules.length + 8))
    const inset = Math.floor((size - scale * code.modules.length) / 2)
    code.modules.forEach((row, y) => [...row].forEach((value, x) => {
      if (value !== '1') return
      for (let py = 0; py < scale; py++) {
        for (let px = 0; px < scale; px++) {
          const offset = ((inset + y * scale + py) * width + index * size + inset + x * scale + px) * 4
          pixels.fill(0, offset, offset + 3)
        }
      }
    }))
  })
  return { width, height: size, getContext: () => ({ getImageData(x, y, w, h) {
    const data = new Uint8ClampedArray(w * h * 4)
    for (let row = 0; row < h; row++) {
      data.set(pixels.subarray(((y + row) * width + x) * 4, ((y + row) * width + x + w) * 4), row * w * 4)
    }
    return { data }
  } }) }
}

test('decodes the exact recipient payload from a real QR matrix', () => {
  assert.equal(new Controller().decode(canvas([fixtures[0]])), fixtures[0].payload)
})

test('refuses two distinct recipients instead of picking the first QR', () => {
  assert.throws(() => new Controller().decode(canvas(fixtures)), /nhiều mã QR khác nhau/)
})

test('a blank image produces no recipient suggestion', () => {
  const blank = { width: 100, height: 100, getContext: () => ({ getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4).fill(255) }) }) }
  assert.equal(new Controller().decode(blank), null)
})
