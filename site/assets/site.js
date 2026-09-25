// Theme toggle (follows the OS until clicked), mobile menu, copy buttons.
(function () {
  var root = document.documentElement
  function applyShots() {
    var forced = root.dataset.theme
    document.querySelectorAll('picture source[media]').forEach(function (s) {
      s.media = forced === 'dark' ? 'all' : forced === 'light' ? 'not all' : '(prefers-color-scheme: dark)'
    })
  }
  applyShots()
  document.querySelector('.theme').addEventListener('click', function () {
    var dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches
    root.dataset.theme = dark ? 'light' : 'dark'
    try { localStorage.setItem('omajot-theme', root.dataset.theme) } catch (e) {}
    applyShots()
  })
  var menu = document.querySelector('.menu'), nav = document.getElementById('nav')
  menu.addEventListener('click', function () {
    var open = nav.classList.toggle('open')
    menu.setAttribute('aria-expanded', String(open))
  })
  document.querySelectorAll('pre.cmd').forEach(function (pre) {
    var b = document.createElement('button')
    b.className = 'copy'; b.type = 'button'; b.textContent = 'Copy'
    b.addEventListener('click', function () {
      var text = pre.querySelector('code').innerText.replace(/^\$ /gm, '')
      navigator.clipboard.writeText(text).then(function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy' }, 1400) })
    })
    pre.appendChild(b)
  })
})()
