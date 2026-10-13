#!/usr/bin/env node
// deobfuscate.js — resolve javascript-obfuscator string-array indirection.
//
// Usage: node Scripts/deobfuscate.js <input.js> <output.js>
//
// Safely evaluates ONLY the obfuscator bootstrap (string-array function,
// decoder function, rotation IIFE) inside a bare `vm` context with no
// require/fs/network, then rewrites every `alias(0x…)` decoder call in the
// file as the decoded string literal.

"use strict";
const fs = require("fs");
const vm = require("vm");

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error("usage: node deobfuscate.js <input.js> <output.js>");
  process.exit(1);
}

const src = fs.readFileSync(input, "utf8");

// --- 1. Locate header: `const ALIAS = DECODER;` and the rotation IIFE start.
const head = /^(?:const|var|let) (_0x[0-9a-f]+)=(_0x[0-9a-f]+);/.exec(src);
if (!head) throw new Error("no `const alias=decoder;` header found — not the expected obfuscation shape");
const [, rootAlias, decoderName] = head;
const iifeStart = src.indexOf("(function(", head[0].length);
if (iifeStart < 0 || iifeStart > 400) throw new Error("rotation IIFE not found near file head");

// --- balanced-region scanner that respects string literals
function scanBalanced(text, start, open, close) {
  let depth = 0, i = start, str = null;
  while (i < text.length) {
    const ch = text[i];
    if (str) {
      if (ch === "\\") { i += 2; continue; }
      if (ch === str) str = null;
    } else if (ch === "'" || ch === '"' || ch === "`") {
      str = ch;
    } else if (ch === open) {
      depth++;
    } else if (ch === close) {
      depth--;
      if (depth === 0) return i; // index of the closing char
    }
    i++;
  }
  throw new Error("unbalanced region from offset " + start);
}

function extractFunction(name) {
  const at = src.indexOf("function " + name + "(");
  if (at < 0) throw new Error("function " + name + " not found");
  const openBrace = src.indexOf("{", at);
  const closeBrace = scanBalanced(src, openBrace, "{", "}");
  return src.slice(at, closeBrace + 1);
}

const decoderFn = extractFunction(decoderName);

// The decoder body references the string-array function: `const X = _0xARRAY();`
const arrRef = /=(_0x[0-9a-f]+)\(\);/.exec(decoderFn);
if (!arrRef) throw new Error("string-array reference not found in decoder");
const arrayFn = extractFunction(arrRef[1]);

// Rotation IIFE: balanced parens starting at iifeStart, then optional `;`.
const iifeEnd = scanBalanced(src, iifeStart, "(", ")");
const iife = src.slice(iifeStart, iifeEnd + 1);

// --- 2. Evaluate bootstrap in a bare context (no require/fs/net globals).
const ctx = vm.createContext({}); // pure JS builtins only
vm.runInContext(arrayFn + "\n" + decoderFn + "\n" + iife, ctx, { timeout: 5000 });
const arrayLen = vm.runInContext(arrRef[1] + "().length", ctx);

// Decoder offset: `function D(a,b){ a = a - 0xNN; ... }`
const offsetMatch = /=(_0x[0-9a-f]+)-0x([0-9a-f]+)/.exec(decoderFn);
if (!offsetMatch) throw new Error("decoder index offset not found");
const base = parseInt(offsetMatch[2], 16);

const decode = (i) => {
  try {
    return vm.runInContext(decoderName + "(" + i + ")", ctx, { timeout: 100 });
  } catch { return undefined; }
};

const map = new Map();
for (let i = base; i < base + arrayLen; i++) {
  const v = decode(i);
  if (typeof v === "string") map.set(i, v);
}
console.error(`string array: ${arrayLen} entries, offset 0x${base.toString(16)}, decoded ${map.size}`);

// --- 3. Collect decoder aliases: `X = DECODER` / `X = ALIAS` (transitive).
const aliases = new Set([decoderName, rootAlias]);
let grew = true;
while (grew) {
  grew = false;
  const re = /(_0x[0-9a-f]+)\s*=\s*(_0x[0-9a-f]+)\b/g;
  let m;
  while ((m = re.exec(src))) {
    if (aliases.has(m[2]) && !aliases.has(m[1])) { aliases.add(m[1]); grew = true; }
  }
}
console.error(`aliases: ${aliases.size}`);

// --- 4. Rewrite `alias(0xHEX)` calls to decoded literals.
let resolved = 0, unresolved = 0;
const callRe = new RegExp("\\b(" + [...aliases].join("|") + ")\\((0x[0-9a-f]+)\\)", "g");
const out = src.replace(callRe, (whole, name, hex) => {
  const idx = parseInt(hex, 16);
  if (map.has(idx)) { resolved++; return JSON.stringify(map.get(idx)); }
  unresolved++;
  return whole;
});

fs.mkdirSync(require("path").dirname(output), { recursive: true });
fs.writeFileSync(output, out);
console.error(`resolved ${resolved} decoder calls (${unresolved} left as-is — non-literal or out-of-range)`);
console.error("wrote " + output);
