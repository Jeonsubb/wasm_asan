'use strict';

const fs = require('fs');
const path = require('path');

const POC_DIR = path.resolve(__dirname, '..', 'artifacts', 'poc');

async function load(path) {
  const bytes = fs.readFileSync(path);
  const mod = await WebAssembly.compile(bytes);
  return WebAssembly.instantiate(mod, {});
}

async function runSingle() {
  const { exports } = await load(path.join(POC_DIR, 'mini_asan_singlemem.wasm'));
  const addr = 0x100;
  exports.instrumented_store(addr, 0x41);
  const before = exports.shadow_value(addr);
  exports.corrupt_shadow_via_mem0(addr, 0x7f);
  const after = exports.shadow_value(addr);
  console.log(`[single-mem] shadow before=${before} after_attack=${after}`);
}

async function runMulti() {
  const { exports } = await load(path.join(POC_DIR, 'mini_asan_multimem.wasm'));
  const addr = 0x100;
  exports.instrumented_store(addr, 0x41);
  const before = exports.shadow_value(addr);
  exports.corrupt_mem0_shadow_like(addr, 0x7f);
  const after = exports.shadow_value(addr);
  console.log(`[multi-mem ] shadow before=${before} after_attack=${after}`);
}

async function main() {
  await runSingle();
  await runMulti();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
