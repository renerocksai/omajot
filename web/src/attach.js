// Attachments: content-addressed files referenced from markdown as
// `attachments/<sha256>.<ext>` (docs/PROTOCOL.md §2). Pasted files are hashed,
// kept in the store until uploaded, and shown from a local object URL until
// then, so previews work offline right after pasting.

export const MAX_BLOB = 16 * 1024 * 1024

const EXT = {
  'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp', 'image/svg+xml': 'svg',
  'image/heic': 'heic', 'image/heif': 'heif', 'image/avif': 'avif', 'image/bmp': 'bmp', 'application/pdf': 'pdf',
  'text/plain': 'txt', 'application/zip': 'zip',
}

export function extensionFor(type, name = '') {
  if (EXT[type]) return EXT[type]
  const m = /\.([a-z0-9]{1,8})$/i.exec(name)
  return m ? m[1].toLowerCase() : 'bin'
}

export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('')
}

export function markdownFor(name, file) {
  const label = (file.name || '').replace(/\.[^.]*$/, '').replace(/[\[\]]/g, '')
  return file.type.startsWith('image/')
    ? `![${label === 'image' ? '' : label}](attachments/${name})`
    : `[${label || name}](attachments/${name})`
}

// Re-encodes an image as JPEG, longest side ≤ maxSide, to fit the hub's blob cap.
async function downscale(file, maxSide = 4096, quality = 0.85) {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height))
  const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale))
  canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  return canvas.convertToBlob({ type: 'image/jpeg', quality })
}

export class Attachments {
  constructor(store, onQueued) {
    this.store = store
    this.onQueued = onQueued
    this.local = new Map() // name → object URL for blobs not uploaded yet
  }

  // Object URLs for anything still waiting in the store (after a restart).
  async restore() {
    for (const { name, blob } of await this.store.pendingBlobs()) this.local.set(name, URL.createObjectURL(blob))
  }

  resolve = (name) => this.local.get(name) || 'api/blobs/' + name

  // Returns the markdown to insert for `file`.
  async add(file) {
    let blob = file
    if (blob.size > MAX_BLOB) {
      if (!file.type.startsWith('image/')) throw new Error('larger than 16 MiB')
      blob = await downscale(file)
      if (blob.size > MAX_BLOB) throw new Error('image still larger than 16 MiB after downscaling')
    }
    const bytes = await blob.arrayBuffer()
    const name = (await sha256Hex(bytes)) + '.' + extensionFor(blob.type, file.name)
    const stored = new Blob([bytes], { type: blob.type || 'application/octet-stream' })
    await this.store.putBlob(name, stored)
    this.local.set(name, URL.createObjectURL(stored))
    this.onQueued()
    return markdownFor(name, blob === file ? file : { name: file.name, type: blob.type })
  }
}
