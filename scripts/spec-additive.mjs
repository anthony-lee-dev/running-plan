#!/usr/bin/env node
// Says whether a change to spec/openapi.yaml only adds to the contract.
// Usage: node scripts/spec-additive.mjs <base.yaml> <head.yaml>
// Exit 0: additive (new paths, methods, schemas, optional properties, optional parameters, response codes, enum
// values, tags; wording). Exit 1: something existing was removed or altered, or a file did not parse; the reasons
// are printed. scripts/request-merge.py uses it: an additive change may ride in a feature PR and auto-merge, any
// other stays a spec PR of its own for the human. When unsure it answers "not additive".
import { readFileSync } from "node:fs";
import yaml from "js-yaml";

// Maps whose entries are named things, so a new entry adds without touching what exists.
const MAPS = new Set([
  "paths", "components", "schemas", "properties", "responses", "content", "examples", "parameters", "headers",
  "requestBodies", "securitySchemes", "links", "callbacks",
]);
// Keys that only describe: they may appear or change freely.
const WORDING = new Set(["description", "summary", "title", "example", "examples", "externalDocs"]);

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const show = (path) => path.join(".") || "(root)";

// A map that may grow: one of MAPS (unless it is a schema property that merely has such a name), or a path item
// (a new method on an existing path).
function mayGrow(path) {
  const last = path[path.length - 1];
  const parent = path[path.length - 2];
  if (path.length === 2 && path[0] === "paths") return true;
  return MAPS.has(last) && parent !== "properties";
}

function paramKey(p) {
  return isObject(p) ? (p.$ref ?? `${p.in}:${p.name}`) : JSON.stringify(p);
}

export function compare(base, head, path = [], out = []) {
  const key = path[path.length - 1];
  if (WORDING.has(key) || (typeof key === "string" && key.startsWith("x-"))) return out;
  if (path.join(".") === "info.version") return out;

  if (isObject(base) && isObject(head)) {
    for (const k of Object.keys(base)) {
      if (!(k in head)) {
        if (!WORDING.has(k) && !k.startsWith("x-")) out.push(`${show([...path, k])}: removed`);
        continue;
      }
      compare(base[k], head[k], [...path, k], out);
    }
    if (!mayGrow(path)) {
      for (const k of Object.keys(head)) {
        if (!(k in base) && !WORDING.has(k) && !k.startsWith("x-")) out.push(`${show([...path, k])}: added to something that exists`);
      }
    }
    return out;
  }

  if (Array.isArray(base) && Array.isArray(head)) {
    if (key === "enum") {
      for (const v of base) if (!head.some((h) => same(h, v))) out.push(`${show(path)}: value ${JSON.stringify(v)} removed`);
      return out;
    }
    if (key === "tags" && path.length === 1) {
      for (const t of base) if (!head.some((h) => same(h?.name, t?.name))) out.push(`tags: ${t?.name} removed`);
      return out;
    }
    if (key === "parameters") {
      const byKey = new Map(head.map((p) => [paramKey(p), p]));
      for (const p of base) {
        const k = paramKey(p);
        if (!byKey.has(k)) out.push(`${show(path)}: parameter ${k} removed or moved`);
        else compare(p, byKey.get(k), [...path, k], out);
      }
      const had = new Set(base.map(paramKey));
      for (const p of head) {
        if (had.has(paramKey(p))) continue;
        if (!isObject(p) || p.$ref || p.required === true) out.push(`${show(path)}: new parameter ${paramKey(p)} is required or a reference`);
      }
      return out;
    }
    if (!same(base, head)) out.push(`${show(path)}: list changed`);
    return out;
  }

  if (!same(base, head)) out.push(`${show(path)}: changed`);
  return out;
}

function main() {
  const [basePath, headPath] = process.argv.slice(2);
  if (!basePath || !headPath) {
    console.error("usage: node scripts/spec-additive.mjs <base.yaml> <head.yaml>");
    process.exit(2);
  }
  let base, head;
  try {
    base = yaml.load(readFileSync(basePath, "utf8"));
    head = yaml.load(readFileSync(headPath, "utf8"));
  } catch (e) {
    console.log(`could not read the spec: ${e.message.split("\n")[0]}`);
    process.exit(1);
  }
  const reasons = compare(base, head);
  if (reasons.length === 0) {
    console.log("additive");
    process.exit(0);
  }
  for (const r of reasons.slice(0, 20)) console.log(r);
  if (reasons.length > 20) console.log(`... and ${reasons.length - 20} more`);
  process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
