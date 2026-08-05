// The compiler-truth pass: `native check`'s final verdict comes from the
// pinned external core compiler. Three outcomes, pinned: a well-typed
// core passes, a type error fails with the compiler's diagnostic, and
// the SDK declaration mapping resolves the package specifier.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "compiler_typecheck.mjs");

function run(source: string): { status: number | null; out: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ctc-"));
  const entry = path.join(dir, "core.ts");
  fs.writeFileSync(entry, source);
  const probe = spawnSync(process.execPath, [script, entry], { encoding: "utf8" });
  fs.rmSync(dir, { recursive: true, force: true });
  return { status: probe.status, out: `${probe.stdout ?? ""}${probe.stderr ?? ""}` };
}

const green = `import type { Cmd } from "@native-sdk/core";
export interface Model { count: number; }
export type Msg = { kind: "tick" };
export function init(): Model { return { count: 0 }; }
export function update(m: Model, msg: Msg): Model { return { count: m.count + 1 }; }
`;

test("a well-typed core passes the compiler-truth pass", () => {
  const r = run(green);
  assert.equal(r.status, 0, r.out);
});

test("a type error fails with the compiler's diagnostic", () => {
  const r = run(green.replace("{ count: 0 }", '{ count: "zero" }'));
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /TypeScript error|SC0001/);
});
