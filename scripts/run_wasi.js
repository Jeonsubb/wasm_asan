'use strict';

const fs = require('fs');
const { WASI } = require('wasi');

function buildEnvImports() {
  const cache = Object.create(null);
  cache.setTempRet0 = () => {};
  cache.emscripten_notify_memory_growth = () => {};

  return new Proxy(cache, {
    get(target, prop) {
      if (!(prop in target)) {
        target[prop] = () => 0;
      }
      return target[prop];
    },
  });
}

async function main() {
  if (process.argv.length < 3) {
    console.error('Usage: node run_wasi.js <wasm> [program-args ...]');
    process.exit(2);
  }

  const wasmPath = process.argv[2];
  const programArgs = process.argv.slice(3);
  const wasi = new WASI({
    args: [wasmPath, ...programArgs],
    env: process.env,
    preopens: { '/': '/' },
  });

  const bytes = fs.readFileSync(wasmPath);
  const mod = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: buildEnvImports(),
  });

  wasi.start(instance);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
