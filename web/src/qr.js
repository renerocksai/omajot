// A QR code matrix from the core (`{cmd:"qr"}` → {size, rows}) as an SVG.
// One unit per module in the viewBox, a white quiet zone around it, and dark
// modules merged into horizontal runs of one path: crisp at any CSS size
// (shape-rendering: crispEdges), black on white whatever the theme.

export const QUIET = 4

// Dark runs per row: [[x, y, length], …] in module coordinates (no quiet zone).
export function darkRuns(rows) {
  const runs = []
  rows.forEach((row, y) => {
    let x = 0
    while (x < row.length) {
      if (row[x] !== '1') { x++; continue }
      const start = x
      while (x < row.length && row[x] === '1') x++
      runs.push([start, y, x - start])
    }
  })
  return runs
}

export function qrSvg({ size, rows }, label = 'QR code') {
  if (!Number.isInteger(size) || size < 21 || rows.length !== size || rows.some(r => r.length !== size)) {
    throw new Error('qrSvg: not a square QR matrix')
  }
  const total = size + 2 * QUIET
  const d = darkRuns(rows).map(([x, y, n]) => `M${x + QUIET} ${y + QUIET}h${n}v1h-${n}z`).join('')
  return `<svg class="qr-code" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${total}" ` +
    `shape-rendering="crispEdges" role="img" aria-label="${label.replace(/"/g, '&quot;')}" data-modules="${size}">` +
    `<rect width="${total}" height="${total}" fill="#fff"/><path fill="#000" d="${d}"/></svg>`
}
