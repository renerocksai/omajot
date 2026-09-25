// Video harness only, never shipped: plays a short scripted session in the
// web app inside the iOS simulator while `simctl io recordVideo` records it.
// The simulator has no touch injection, so taps are clicks and the pull to
// refresh is synthetic touch events on the note list.
(function () {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  async function until(fn, ms = 15000) { const t = Date.now(); while (!fn() && Date.now() - t < ms) await sleep(100) }
  const button = (text) => [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === text)

  async function scroll(el, to, ms) {
    const from = el.scrollTop, t0 = performance.now()
    for (;;) {
      const k = Math.min(1, (performance.now() - t0) / ms)
      el.scrollTop = from + (to - from) * (0.5 - Math.cos(Math.PI * k) / 2)
      if (k === 1) return
      await sleep(16)
    }
  }

  async function pull(el) {
    const r = el.getBoundingClientRect(), x = r.left + r.width / 2, y0 = r.top + 30
    const touch = (y) => new Touch({ identifier: 1, target: el, clientX: x, clientY: y, pageX: x, pageY: y })
    const fire = (type, y) => el.dispatchEvent(new TouchEvent(type, {
      touches: type === 'touchend' ? [] : [touch(y)], changedTouches: [touch(y)], bubbles: true, cancelable: true }))
    fire('touchstart', y0)
    for (let dy = 0; dy <= 120; dy += 6) { fire('touchmove', y0 + dy); await sleep(28) }
    await sleep(350)
    fire('touchend', y0 + 120)
  }

  async function run() {
    await until(() => document.querySelectorAll('.nrow').length > 5 || button('Use here'), 8000)
    if (button('Use here')) { button('Use here').click(); await sleep(500) }
    await until(() => document.querySelectorAll('.nrow').length > 5)
    const list = document.querySelector('.notes.scroll')
    await sleep(1400)
    await scroll(list, 260, 900)
    await sleep(500)
    await scroll(list, 0, 700)
    await sleep(500)
    ;[...document.querySelectorAll('.nrow')].find((r) => r.textContent.includes('Lisbon in October'))?.click()
    await until(() => document.querySelector('.cm-content')?.textContent.includes('Lisbon'))
    for (let i = 0; i < 4 && document.querySelector('.app')?.dataset.mode !== 'preview'; i++) {
      document.querySelector('.toolbar [data-act="mode"]')?.click()
      await sleep(200)
    }
    document.activeElement?.blur()
    await sleep(1600)
    const preview = document.querySelector('.preview')
    if (preview) { await scroll(preview, 420, 1400); await sleep(900); await scroll(preview, 0, 800) }
    await sleep(500)
    document.querySelector('[data-act="to-list"]')?.click()
    await sleep(1200)
    await pull(list)
    await sleep(2500)
    document.body.dataset.demo = 'done'
  }
  addEventListener('load', run)
})()
