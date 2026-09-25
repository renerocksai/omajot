// Builds web/dist: bundles app.js (CodeMirror included) and app.css, copies
// the shell and icons, copies core.wasm from ../zig-out/web (run
// `zig build wasm` first), and stamps a content version into index.html and
// sw.js so clients pick up new builds. `--watch` rebuilds on changes.
import * as esbuild from 'esbuild'
import { createHash } from 'node:crypto'
import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { existsSync, watch } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const src = join(root, 'src')
const dist = join(root, 'dist')
const wasm = join(root, '..', 'zig-out', 'web', 'core.wasm')

async function build() {
  const t0 = Date.now()
  const keepWasm = existsSync(join(dist, 'core.wasm')) ? await readFile(join(dist, 'core.wasm')) : null
  await rm(dist, { recursive: true, force: true })
  await mkdir(join(dist, 'icons'), { recursive: true })

  await esbuild.build({
    entryPoints: [join(src, 'app.js')], outfile: join(dist, 'app.js'),
    bundle: true, format: 'esm', minify: true, target: ['es2022', 'safari16'], legalComments: 'none', logLevel: 'warning',
  })
  await esbuild.build({
    entryPoints: [join(src, 'app.css')], outfile: join(dist, 'app.css'), bundle: true, minify: true, logLevel: 'warning',
  })
  for (const f of await readdir(join(src, 'icons'))) await cp(join(src, 'icons', f), join(dist, 'icons', f))
  await cp(join(src, 'manifest.webmanifest'), join(dist, 'manifest.webmanifest'))

  if (existsSync(wasm)) await cp(wasm, join(dist, 'core.wasm'))
  else if (keepWasm) { await writeFile(join(dist, 'core.wasm'), keepWasm); console.warn('build: ../zig-out/web/core.wasm missing, kept the previous dist/core.wasm') }
  else console.warn('build: no core.wasm (run `zig build wasm`); the app will fall back to the mock engine')

  const assets = ['./', 'app.js', 'app.css', 'manifest.webmanifest',
    ...(await readdir(join(dist, 'icons'))).map(f => 'icons/' + f)]
  if (existsSync(join(dist, 'core.wasm'))) assets.push('core.wasm')

  const hash = createHash('sha256')
  for (const a of assets.slice(1)) hash.update(await readFile(join(dist, a)))
  hash.update(await readFile(join(src, 'index.html')))
  hash.update(await readFile(join(src, 'sw.js')))
  const version = hash.digest('hex').slice(0, 12)

  await writeFile(join(dist, 'index.html'), (await readFile(join(src, 'index.html'), 'utf8')).replaceAll('__VERSION__', version))
  await writeFile(join(dist, 'sw.js'), (await readFile(join(src, 'sw.js'), 'utf8'))
    .replaceAll('__VERSION__', version).replaceAll('__ASSETS__', JSON.stringify(assets)))

  const size = (await stat(join(dist, 'app.js'))).size
  console.log(`built dist/ version ${version} (app.js ${(size / 1024).toFixed(0)} KiB) in ${Date.now() - t0} ms`)
}

await build()
if (process.argv.includes('--watch')) {
  let timer = null
  const again = () => { clearTimeout(timer); timer = setTimeout(() => build().catch(e => console.error(e.message)), 100) }
  watch(src, { recursive: true }, again)
  if (existsSync(dirname(wasm))) watch(dirname(wasm), again)
  console.log('watching src/ and ../zig-out/web/')
}
