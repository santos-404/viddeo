#!/usr/bin/env node
// sync-sources.js — keep Viddeo.xcodeproj's Sources group/build phase in step with
// the flat directory Viddeo/Sources/*.swift. Existing file IDs are preserved; new
// files get deterministic IDs derived from the filename. Idempotent.
//
// Usage: node Scripts/sync-sources.js

"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const root = path.resolve(__dirname, "..");
const pbxPath = path.join(root, "Viddeo/Viddeo.xcodeproj/project.pbxproj");
const sourcesDir = path.join(root, "Viddeo/Sources");
const GROUP_ID = "D10000000000000000000002";
const PHASE_ID = "C10000000000000000000002";

let pbx = fs.readFileSync(pbxPath, "utf8");
const files = fs.readdirSync(sourcesDir).filter((f) => f.endsWith(".swift")).sort();

// Existing ids by filename.
const existing = new Map();
for (const m of pbx.matchAll(/(B[0-9A-F]{23}) (?:\/\* ([^*]+?) \*\/ )?= \{isa = PBXFileReference;[^}]*path = ([^;]+);/g)) {
  existing.set(m[3].trim(), m[1]);
}
const buildIds = new Map();
for (const m of pbx.matchAll(/(A[0-9A-F]{23}) \/\* ([^*]+?) in Sources \*\/ = \{isa = PBXBuildFile; fileRef = (B[0-9A-F]{23})/g)) {
  buildIds.set(m[3], m[1]);
}

function hexId(prefix, name) {
  return prefix + crypto.createHash("sha1").update(name).digest("hex").slice(0, 23).toUpperCase();
}

const entries = files.map((name) => {
  const ref = existing.get(name) ?? hexId("B", name);
  const build = buildIds.get(ref) ?? hexId("A", name);
  return { name, ref, build };
});

// Drop all Swift file refs/build files, then re-emit them.
pbx = pbx.replace(/^\t\tA[0-9A-F]{23} \/\* [^*]+\.swift in Sources \*\/ = \{isa = PBXBuildFile;[^\n]*\n/gm, "");
pbx = pbx.replace(/^\t\tB[0-9A-F]{23} (?:\/\* [^*]+\.swift \*\/ )?= \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift;[^\n]*\n/gm, "");

const buildLines = entries.map((e) =>
  `\t\t${e.build} /* ${e.name} in Sources */ = {isa = PBXBuildFile; fileRef = ${e.ref} /* ${e.name} */; };\n`).join("");
const refLines = entries.map((e) =>
  `\t\t${e.ref} /* ${e.name} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${e.name}; sourceTree = "<group>"; };\n`).join("");

pbx = pbx.replace("/* End PBXBuildFile section */", buildLines + "/* End PBXBuildFile section */");
pbx = pbx.replace("/* End PBXFileReference section */", refLines + "/* End PBXFileReference section */");

const groupChildren = entries.map((e) => `${e.ref} /* ${e.name} */, `).join("");
pbx = pbx.replace(
  new RegExp(`(${GROUP_ID} /\\* Sources \\*/ = \\{isa = PBXGroup; children = \\()[^)]*(\\);)`),
  `$1${groupChildren}$2`);
const phaseFiles = entries.map((e) => `${e.build} /* ${e.name} in Sources */, `).join("");
pbx = pbx.replace(
  new RegExp(`(${PHASE_ID} /\\* Sources \\*/ = \\{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = \\()[^)]*(\\);)`),
  `$1${phaseFiles}$2`);

fs.writeFileSync(pbxPath, pbx);
console.log(`sync-sources: ${entries.length} Swift files registered`);
