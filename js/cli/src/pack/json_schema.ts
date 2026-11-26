// Dependency-free JSON Schema structural, `$ref` acyclicity, and runtime value
// validation helpers for Solution Pack v2 (`signal_schemas/*.schema.json`) and
// `vantage dev` RBE-hermetic fallback.
//
// Intentionally imports ONLY `./canonical.js` (no `ajv`, `vite`, etc.) so
// `//js/cli:pack_test` and `//js/cli:vantage_test` stay hermetic under
// `cli_bundle.mjs`.

import {isPlainObject, type PackValidationIssue} from "./canonical.js"

const SCHEMA_TYPES = new Set([
  "object",
  "array",
  "string",
  "number",
  "integer",
  "boolean",
  "null",
])

export function resolveJsonPointer(root: unknown, pointer: string): {found: boolean; value: unknown} {
  if (pointer === "#" || pointer === "") {
    return {found: true, value: root}
  }
  if (!pointer.startsWith("#/")) {
    return {found: false, value: undefined}
  }
  const tokens = pointer
    .slice(2)
    .split("/")
    .map((seg) => seg.replace(/~1/g, "/").replace(/~0/g, "~"))

  let current: unknown = root
  for (const token of tokens) {
    if (Array.isArray(current)) {
      if (!/^\d+$/.test(token)) return {found: false, value: undefined}
      const idx = Number(token)
      if (idx < 0 || idx >= current.length) return {found: false, value: undefined}
      current = current[idx]
    } else if (isPlainObject(current)) {
      if (!Object.prototype.hasOwnProperty.call(current, token)) {
        return {found: false, value: undefined}
      }
      current = current[token]
    } else {
      return {found: false, value: undefined}
    }
  }
  return {found: true, value: current}
}

export function validateJsonSchemaDocument(
  schema: unknown,
  file: string,
  issues: PackValidationIssue[],
): void {
  if (!isPlainObject(schema)) {
    issues.push({
      file,
      path: "$",
      code: "invalid_signal_schema",
      message: "signal schema document must be a JSON object",
    })
    return
  }

  const hasStructuralKeyword =
    typeof schema.type === "string" ||
    Array.isArray(schema.type) ||
    isPlainObject(schema.properties) ||
    isPlainObject(schema.$defs) ||
    isPlainObject(schema.definitions) ||
    Array.isArray(schema.allOf) ||
    Array.isArray(schema.anyOf) ||
    Array.isArray(schema.oneOf) ||
    typeof schema.$ref === "string"

  if (!hasStructuralKeyword) {
    issues.push({
      file,
      path: "$",
      code: "invalid_signal_schema",
      message: "signal schema must declare type, properties, $defs, combinators, or $ref",
    })
  }

  validateSchemaNodeAndRefs(schema, schema, "$", new Set<string>(), file, issues)
}

function validateSchemaNodeAndRefs(
  root: Record<string, unknown>,
  node: unknown,
  jsonPath: string,
  activeRefs: Set<string>,
  file: string,
  issues: PackValidationIssue[],
): void {
  if (Array.isArray(node)) {
    node.forEach((item, idx) =>
      validateSchemaNodeAndRefs(root, item, `${jsonPath}[${idx}]`, activeRefs, file, issues),
    )
    return
  }
  if (!isPlainObject(node)) {
    return
  }

  if (node.type !== undefined) {
    if (typeof node.type === "string") {
      if (!SCHEMA_TYPES.has(node.type)) {
        issues.push({
          file,
          path: `${jsonPath}.type`,
          code: "invalid_json_schema_type",
          message: `unsupported JSON Schema type ${JSON.stringify(node.type)}`,
        })
      }
    } else if (Array.isArray(node.type)) {
      for (const entry of node.type) {
        if (typeof entry !== "string" || !SCHEMA_TYPES.has(entry)) {
          issues.push({
            file,
            path: `${jsonPath}.type`,
            code: "invalid_json_schema_type",
            message: `unsupported JSON Schema type entry ${JSON.stringify(entry)}`,
          })
        }
      }
    } else if (!isPlainObject(node.properties) || !("type" in node.properties)) {
      // Allow `properties.type` object when validating a schema's `properties` map itself;
      // here `node` is a schema node so `type` must be string or string[].
      issues.push({
        file,
        path: `${jsonPath}.type`,
        code: "invalid_json_schema_type",
        message: "JSON Schema `type` must be a string or array of type strings",
      })
    }
  }

  if (typeof node.pattern === "string") {
    try {
      new RegExp(node.pattern)
    } catch (err: any) {
      issues.push({
        file,
        path: `${jsonPath}.pattern`,
        code: "invalid_json_schema_pattern",
        message: `invalid regex pattern ${JSON.stringify(node.pattern)}: ${err?.message || String(err)}`,
      })
    }
  }

  if (node.$ref !== undefined) {
    if (typeof node.$ref !== "string" || node.$ref.trim() === "") {
      issues.push({
        file,
        path: `${jsonPath}.$ref`,
        code: "invalid_json_schema_ref",
        message: "$ref must be a non-empty JSON pointer string",
      })
    } else {
      const ref = node.$ref.trim()
      if (ref !== "#" && !ref.startsWith("#/")) {
        issues.push({
          file,
          path: `${jsonPath}.$ref`,
          code: "external_json_schema_ref",
          message: `external $ref ${JSON.stringify(ref)} is forbidden; use internal "#/$defs/..." references`,
        })
      } else if (activeRefs.has(ref)) {
        issues.push({
          file,
          path: `${jsonPath}.$ref`,
          code: "circular_json_schema_ref",
          message: `circular JSON Schema $ref cycle detected at "${ref}"`,
        })
      } else {
        const resolved = resolveJsonPointer(root, ref)
        if (!resolved.found) {
          issues.push({
            file,
            path: `${jsonPath}.$ref`,
            code: "unresolved_json_schema_ref",
            message: `unresolved internal JSON Schema $ref "${ref}"`,
          })
        } else {
          const nextRefs = new Set(activeRefs)
          nextRefs.add(ref)
          validateSchemaNodeAndRefs(root, resolved.value, `${jsonPath}->${ref}`, nextRefs, file, issues)
        }
      }
    }
  }

  if (isPlainObject(node.properties)) {
    for (const [propName, propSchema] of Object.entries(node.properties)) {
      validateSchemaNodeAndRefs(
        root,
        propSchema,
        `${jsonPath}.properties.${propName}`,
        activeRefs,
        file,
        issues,
      )
    }
  }
  if (isPlainObject(node.$defs)) {
    for (const [defName, defSchema] of Object.entries(node.$defs)) {
      validateSchemaNodeAndRefs(
        root,
        defSchema,
        `${jsonPath}.$defs.${defName}`,
        activeRefs,
        file,
        issues,
      )
    }
  }
  if (isPlainObject(node.definitions)) {
    for (const [defName, defSchema] of Object.entries(node.definitions)) {
      validateSchemaNodeAndRefs(
        root,
        defSchema,
        `${jsonPath}.definitions.${defName}`,
        activeRefs,
        file,
        issues,
      )
    }
  }
  if (node.items !== undefined) {
    validateSchemaNodeAndRefs(root, node.items, `${jsonPath}.items`, activeRefs, file, issues)
  }
  if (isPlainObject(node.additionalProperties)) {
    validateSchemaNodeAndRefs(
      root,
      node.additionalProperties,
      `${jsonPath}.additionalProperties`,
      activeRefs,
      file,
      issues,
    )
  }
  for (const combKey of ["allOf", "anyOf", "oneOf"] as const) {
    if (Array.isArray(node[combKey])) {
      node[combKey].forEach((sub, idx) =>
        validateSchemaNodeAndRefs(root, sub, `${jsonPath}.${combKey}[${idx}]`, activeRefs, file, issues),
      )
    }
  }
  if (node.not !== undefined) {
    validateSchemaNodeAndRefs(root, node.not, `${jsonPath}.not`, activeRefs, file, issues)
  }
}

// Pure-TS JSON Schema value validator used as an RBE-hermetic fallback when
// `ajv/dist/2020.js` is externalized/unavailable.
export function validateValueAgainstJsonSchema(
  value: unknown,
  schema: Record<string, unknown>,
  root: Record<string, unknown> = schema,
  path = "$",
  visitedRefs: Set<string> = new Set(),
): string[] {
  const errors: string[] = []

  if (typeof schema.$ref === "string") {
    const ref = schema.$ref.trim()
    if (visitedRefs.has(ref)) {
      errors.push(`${path}: circular $ref "${ref}"`)
      return errors
    }
    const resolved = resolveJsonPointer(root, ref)
    if (!resolved.found || !isPlainObject(resolved.value)) {
      errors.push(`${path}: unresolved $ref "${ref}"`)
      return errors
    }
    const nextVisited = new Set(visitedRefs)
    nextVisited.add(ref)
    errors.push(...validateValueAgainstJsonSchema(value, resolved.value, root, path, nextVisited))
  }

  if (schema.type !== undefined) {
    const allowed = Array.isArray(schema.type) ? schema.type : [schema.type]
    if (!allowed.some((t) => matchesSchemaType(value, String(t)))) {
      errors.push(`${path}: expected type ${allowed.join(" | ")}, got ${describeType(value)}`)
      return errors
    }
  }

  if (Array.isArray(schema.enum) && !schema.enum.some((entry) => deepEqual(entry, value))) {
    errors.push(`${path}: value must be one of ${JSON.stringify(schema.enum)}`)
  }
  if ("const" in schema && !deepEqual(schema.const, value)) {
    errors.push(`${path}: value must equal ${JSON.stringify(schema.const)}`)
  }

  if (typeof value === "string") {
    if (typeof schema.minLength === "number" && value.length < schema.minLength) {
      errors.push(`${path}: string length ${value.length} < minLength ${schema.minLength}`)
    }
    if (typeof schema.maxLength === "number" && value.length > schema.maxLength) {
      errors.push(`${path}: string length ${value.length} > maxLength ${schema.maxLength}`)
    }
    if (typeof schema.pattern === "string") {
      const re = new RegExp(schema.pattern)
      if (!re.test(value)) {
        errors.push(`${path}: string ${JSON.stringify(value)} does not match pattern ${schema.pattern}`)
      }
    }
  }

  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) {
      errors.push(`${path}: ${value} < minimum ${schema.minimum}`)
    }
    if (typeof schema.maximum === "number" && value > schema.maximum) {
      errors.push(`${path}: ${value} > maximum ${schema.maximum}`)
    }
    if (typeof schema.exclusiveMinimum === "number" && value <= schema.exclusiveMinimum) {
      errors.push(`${path}: ${value} <= exclusiveMinimum ${schema.exclusiveMinimum}`)
    }
    if (typeof schema.exclusiveMaximum === "number" && value >= schema.exclusiveMaximum) {
      errors.push(`${path}: ${value} >= exclusiveMaximum ${schema.exclusiveMaximum}`)
    }
  }

  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) {
      errors.push(`${path}: array length ${value.length} < minItems ${schema.minItems}`)
    }
    if (typeof schema.maxItems === "number" && value.length > schema.maxItems) {
      errors.push(`${path}: array length ${value.length} > maxItems ${schema.maxItems}`)
    }
    if (isPlainObject(schema.items)) {
      value.forEach((item, idx) => {
        errors.push(
          ...validateValueAgainstJsonSchema(
            item,
            schema.items as Record<string, unknown>,
            root,
            `${path}[${idx}]`,
            visitedRefs,
          ),
        )
      })
    }
  }

  if (isPlainObject(value)) {
    const props = isPlainObject(schema.properties) ? schema.properties : {}
    if (Array.isArray(schema.required)) {
      for (const reqKey of schema.required) {
        if (typeof reqKey === "string" && !Object.prototype.hasOwnProperty.call(value, reqKey)) {
          errors.push(`${path}: missing required property "${reqKey}"`)
        }
      }
    }
    for (const [k, v] of Object.entries(value)) {
      if (Object.prototype.hasOwnProperty.call(props, k)) {
        const propSchema = props[k]
        if (isPlainObject(propSchema)) {
          errors.push(
            ...validateValueAgainstJsonSchema(v, propSchema, root, `${path}.${k}`, visitedRefs),
          )
        }
      } else if (schema.additionalProperties === false) {
        errors.push(`${path}: unexpected additional property "${k}"`)
      } else if (isPlainObject(schema.additionalProperties)) {
        errors.push(
          ...validateValueAgainstJsonSchema(
            v,
            schema.additionalProperties,
            root,
            `${path}.${k}`,
            visitedRefs,
          ),
        )
      }
    }
  }

  if (Array.isArray(schema.allOf)) {
    for (const sub of schema.allOf) {
      if (isPlainObject(sub)) {
        errors.push(...validateValueAgainstJsonSchema(value, sub, root, path, visitedRefs))
      }
    }
  }
  if (Array.isArray(schema.anyOf)) {
    const subs = schema.anyOf.filter(isPlainObject)
    if (
      subs.length > 0 &&
      !subs.some((sub) => validateValueAgainstJsonSchema(value, sub, root, path, visitedRefs).length === 0)
    ) {
      errors.push(`${path}: value does not satisfy anyOf`)
    }
  }
  if (Array.isArray(schema.oneOf)) {
    const subs = schema.oneOf.filter(isPlainObject)
    const matched = subs.filter(
      (sub) => validateValueAgainstJsonSchema(value, sub, root, path, visitedRefs).length === 0,
    ).length
    if (subs.length > 0 && matched !== 1) {
      errors.push(`${path}: value must satisfy exactly one of oneOf (matched ${matched})`)
    }
  }

  return errors
}

function matchesSchemaType(value: unknown, type: string): boolean {
  switch (type) {
    case "object":
      return isPlainObject(value)
    case "array":
      return Array.isArray(value)
    case "string":
      return typeof value === "string"
    case "number":
      return typeof value === "number" && Number.isFinite(value)
    case "integer":
      return typeof value === "number" && Number.isInteger(value)
    case "boolean":
      return typeof value === "boolean"
    case "null":
      return value === null
    default:
      return false
  }
}

function describeType(value: unknown): string {
  if (value === null) return "null"
  if (Array.isArray(value)) return "array"
  return typeof value
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((v, idx) => deepEqual(v, b[idx]))
  }
  if (isPlainObject(a) && isPlainObject(b)) {
    const keysA = Object.keys(a)
    const keysB = Object.keys(b)
    return (
      keysA.length === keysB.length &&
      keysA.every((k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]))
    )
  }
  return false
}
