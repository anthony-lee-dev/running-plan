// Reads `spec/openapi.yaml` and checks requests and responses against it. Runs in Node and in workerd: the
// validator interprets schemas (no `eval`), and the spec comes in as text through Vite's `?raw` import.
import { Validator, type Schema } from "@cfworker/json-schema";
import { load } from "js-yaml";
import specText from "../../../spec/openapi.yaml?raw";

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const BASE = "https://running-plan.invalid/openapi.json";
export const spec = load(specText) as Json;

// JSON pointer to a spot in the spec, URI-encoded the way the validator keys its sub-schemas (`{id}` is `%7Bid%7D`).
const pointer = (...parts: string[]) => "#/" + parts.map((p) => encodeURI(p.replaceAll("~", "~0").replaceAll("/", "~1"))).join("/");

/** Every operation in the spec as `METHOD /path/{param}`. */
export const specOperations = (): string[] =>
  Object.entries(spec.paths as Json).flatMap(([path, item]) =>
    Object.keys(item as Json)
      .filter((m) => ["get", "post", "put", "patch", "delete"].includes(m))
      .map((m) => `${m.toUpperCase()} ${path}`),
  );

const validators = new Map<string, Validator>();
/** Validates against the schema at a JSON pointer in the spec, resolving its `#/components/...` refs. */
function validatorAt(ptr: string): Validator {
  let v = validators.get(ptr);
  if (!v) {
    v = new Validator({ $ref: BASE + ptr } as Schema, "2020-12", false);
    v.addSchema(spec as Schema, BASE);
    validators.set(ptr, v);
  }
  return v;
}

const errorsOf = (ptr: string, value: unknown) =>
  validatorAt(ptr)
    .validate(value)
    .errors.map((e) => `${e.instanceLocation} ${e.error}`);

function operation(op: string): Json {
  const [method, path] = op.split(" ") as [string, string];
  const found = (spec.paths as Json)[path]?.[method.toLowerCase()];
  if (!found) throw new Error(`${op} is not in the spec`);
  return found;
}

/** Follows a `$ref` to `#/components/responses/...`. */
const resolve = (node: Json): Json => (node.$ref ? (spec.components.responses as Json)[String(node.$ref).split("/").pop()!] : node);

/** Schema errors for a request body (empty when it is valid), as `<instance pointer> <message>`. */
export function requestErrors(op: string, body: unknown): string[] {
  const [method, path] = op.split(" ") as [string, string];
  if (!operation(op).requestBody) throw new Error(`${op} takes no body`);
  return errorsOf(pointer("paths", path, method.toLowerCase(), "requestBody", "content", "application/json", "schema"), body);
}

/** Fills a spec path's `{params}` with placeholders: a uuid, or 0 for an index. */
export const placeholderPath = (path: string) =>
  path.replace(/\{(\w+)\}/g, (_, name: string) => (name.endsWith("Index") ? "0" : "00000000-0000-4000-8000-00000000abcd"));

/** What is wrong with a response: an undocumented status, the wrong content type, or a body off its schema. */
export async function responseErrors(op: string, res: Response): Promise<string[]> {
  const [method, path] = op.split(" ") as [string, string];
  const responses = operation(op).responses as Json;
  const status = String(res.status);
  // No `default` responses: the validator does not index sub-schemas under a `default` key.
  const key = status in responses ? status : undefined;
  const text = await res.text();
  if (!key) return [`${op}: status ${status} is not documented (body: ${text.slice(0, 200)})`];
  const content = resolve(responses[key]).content as Json | undefined;
  if (!content) return text === "" ? [] : [`${op} ${status}: the spec has no body but got ${text.slice(0, 200)}`];
  const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim();
  if (!(type in content)) return [`${op} ${status}: content type ${type || "(none)"}, expected ${Object.keys(content).join(" or ")}`];
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return [`${op} ${status}: body is not JSON: ${text.slice(0, 200)}`];
  }
  const ptr = responses[key].$ref
    ? pointer("components", "responses", String(responses[key].$ref).split("/").pop()!, "content", type, "schema")
    : pointer("paths", path, method.toLowerCase(), "responses", key, "content", type, "schema");
  return errorsOf(ptr, body).map((e) => `${op} ${status}: ${e}`);
}
