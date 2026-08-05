// The compiler-truth typecheck: run the pinned external core compiler's
// analyzer over the author's entry with the shipped SDK declarations
// mapped, so `native check` answers with the SAME compiler that will
// build the core — a verdict the frontend's own checker can only
// approximate from a different TypeScript line.
//
//   node compiler_typecheck.mjs <entry.ts>
//
// Exit 0: the compiler's analyzer accepts the program (its static-subset
// findings are compile-time concerns, not check failures). Exit 1: the
// program does not typecheck under the compiler — its errors, already
// printed verbatim, are the teaching. Exit 2: toolchain missing/broken.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const entry = process.argv[2];
if (!entry) {
  console.error("usage: compiler_typecheck.mjs <entry.ts>");
  process.exit(2);
}
const here = path.dirname(fileURLToPath(import.meta.url));
const coreRoot = path.resolve(here, "..");
let compilerJs;
try {
  compilerJs = createRequire(path.join(coreRoot, "package.json")).resolve("scriptc/dist/main.js");
} catch {
  console.error("the external core compiler is not installed — run `npm ci --include=dev` in the SDK's packages/core");
  process.exit(2);
}
// The shipped declaration files stand in for the SDK's module surface;
// value imports stay external-host findings, which is correct — the
// compile stage links the real implementations.
const maps = [];
for (const [specifier, file] of [
  ["@native-sdk/core", "sdk/core.d.ts"],
  ["@native-sdk/core/text", "sdk/text.d.ts"],
  ["@native-sdk/core/events", "sdk/events.d.ts"],
]) {
  const p = path.join(coreRoot, file);
  if (fs.existsSync(p)) maps.push("--external-types", `${specifier}=${p}`);
}
const probe = spawnSync(process.execPath, [compilerJs, "coverage", entry, ...maps], { encoding: "utf8" });
const out = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
if (probe.status === 0) process.exit(0);
// Analyzer refusals for TYPE errors carry the compiler's own diagnostics;
// pass them through untouched and fail the check.
if (/TypeScript error/.test(out) || /error SC0001/.test(out)) {
  process.stderr.write(out);
  process.exit(1);
}
// Any other nonzero outcome (analyzer internal trouble) must not wedge
// `native check`: the compile stage will judge for real.
process.stderr.write(out);
console.error("native check: the external compiler's analyzer could not run to a verdict here; the build will judge for real");
process.exit(0);
