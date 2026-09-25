// Runs the same checks as index.html under node: `node node-test.mjs` after `zig build web`.
import { readFile } from "node:fs/promises";
import { loadCore, runChecks } from "./zig-out/web/glue.js";

const core = await loadCore(await readFile(new URL("./zig-out/web/core.wasm", import.meta.url)));
const results = runChecks(core);
for (const r of results) console.log(`${r.ok ? "PASS" : "FAIL"} ${r.name}${r.detail ? " — " + r.detail : ""}`);
console.log(`1000 edits on a ${(7000*30/1024)|0} KB note: ${globalThis.__bigEditMs?.toFixed(1)} ms`);
const failed = results.filter((r) => !r.ok).length;
console.log(failed ? `FAILED ${failed}` : `ALL PASS (${results.length})`);
process.exit(failed ? 1 : 0);
