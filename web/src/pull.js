// Pull to refresh for the note and folder lists. A home-screen web app on iOS
// has no browser reload, so pulling down at the top of a list syncs now and
// loads a new omajot version if there is one.

// How far (px) the finger must travel down from the top of the list.
export const PULL_THRESHOLD = 70

// The phase for a pull of `dy` px that started with the list at its top.
export function pullPhase(atTop, dy) {
  if (!atTop || dy <= 8) return 'idle'
  return dy >= PULL_THRESHOLD ? 'release' : 'pull'
}

const LABELS = { pull: 'Pull to sync', release: 'Release to sync' }

// Watch `el` (a scroll container) for pulls; `refresh(show)` runs on release
// and reports progress through `show(text)`.
export function attachPull(el, indicator, refresh) {
  let startY = null
  let phase = 'idle'
  let busy = false

  const show = (text) => {
    indicator.textContent = text
    indicator.classList.toggle('on', !!text)
  }

  el.addEventListener('touchstart', (e) => {
    if (busy || e.touches.length !== 1) return
    startY = el.scrollTop <= 0 ? e.touches[0].clientY : null
  }, { passive: true })

  el.addEventListener('touchmove', (e) => {
    if (startY === null) return
    phase = pullPhase(el.scrollTop <= 0, e.touches[0].clientY - startY)
    show(LABELS[phase] || '')
  }, { passive: true })

  const end = async () => {
    const run = phase === 'release'
    startY = null
    phase = 'idle'
    if (!run) return show('')
    busy = true
    try {
      await refresh(show)
    } finally {
      busy = false
      setTimeout(() => show(''), 900)
    }
  }
  el.addEventListener('touchend', end)
  el.addEventListener('touchcancel', () => { startY = null; phase = 'idle'; show('') })
}
