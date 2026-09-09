import {describe, expect, test} from "vitest"

import {baseFieldName, isDynamicKeyField, isValidJsonbKey, tokenize} from "./tokenizer.js"

describe("SRQL tokenizer", () => {
  test("empty input starts at the control slot", () => {
    const result = tokenize("", 0)

    expect(result.tokens).toEqual([])
    expect(result.slot).toBe("control")
    expect(result.activeRange).toEqual({start: 0, end: 0})
  })

  test("in: places the cursor in an entity slot", () => {
    const result = tokenize("in:", 3)

    expect(result.slot).toBe("entity")
    expect(result.activeRange).toEqual({start: 3, end: 3})
  })

  test("where followed by whitespace places the cursor in a field slot", () => {
    const result = tokenize("in:devices where ", "in:devices where ".length)

    expect(result.entity).toBe("devices")
    expect(result.slot).toBe("field")
    expect(result.activeRange).toEqual({start: 17, end: 17})
  })

  test("field operator value segments are classified", () => {
    const result = tokenize("hostname:srv", "hostname:srv".length)

    expect(result.tokens).toEqual([
      {start: 0, end: 8, kind: "field", text: "hostname"},
      {start: 8, end: 9, kind: "op", text: ":"},
      {start: 9, end: 12, kind: "value", text: "srv"},
    ])
    expect(result.slot).toBe("value")
  })

  test("mid-token cursor returns the active token", () => {
    const result = tokenize("in:devices hostname:srv", 6)

    expect(result.activeToken).toEqual({start: 3, end: 10, kind: "entity", text: "devices"})
    expect(result.slot).toBe("entity")
  })

  test("trailing whitespace returns to control slot", () => {
    const result = tokenize("in:devices ", "in:devices ".length)

    expect(result.slot).toBe("control")
  })

  test("multi-clause query infers the value slot at the cursor", () => {
    const result = tokenize("in:devices hostname:srv ip:10.", "in:devices hostname:srv ip:10.".length)

    expect(result.entity).toBe("devices")
    expect(result.activeToken).toEqual({start: 27, end: 30, kind: "value", text: "10."})
    expect(result.slot).toBe("value")
  })

  test("quoted values can contain whitespace", () => {
    const result = tokenize("in:devices hostname:\"my server\"", "in:devices hostname:\"my server\"".length)

    expect(result.tokens).toEqual([
      {start: 0, end: 3, kind: "control", text: "in:"},
      {start: 3, end: 10, kind: "entity", text: "devices"},
      {start: 11, end: 19, kind: "field", text: "hostname"},
      {start: 19, end: 20, kind: "op", text: ":"},
      {start: 20, end: 31, kind: "value", text: "\"my server\""},
    ])
    expect(result.slot).toBe("value")
  })

  test("operators inside quoted values are ignored", () => {
    const result = tokenize("in:logs message:\"http://service\"", "in:logs message:\"http://service\"".length)

    expect(result.tokens).toEqual([
      {start: 0, end: 3, kind: "control", text: "in:"},
      {start: 3, end: 7, kind: "entity", text: "logs"},
      {start: 8, end: 15, kind: "field", text: "message"},
      {start: 15, end: 16, kind: "op", text: ":"},
      {start: 16, end: 32, kind: "value", text: "\"http://service\""},
    ])
  })

  test("sort field and direction are classified separately", () => {
    const query = "in:devices ip:%192.168% sort:last_seen:desc limit:100 include_inactive:true"
    const result = tokenize(query, query.length)

    expect(result.tokens).toContainEqual({start: 24, end: 29, kind: "control", text: "sort:"})
    expect(result.tokens).toContainEqual({start: 29, end: 38, kind: "field", text: "last_seen"})
    expect(result.tokens).toContainEqual({start: 38, end: 39, kind: "op", text: ":"})
    expect(result.tokens).toContainEqual({start: 39, end: 43, kind: "value", text: "desc"})
  })

  // These are reserved control tokens, not fields. When they were missing from
  // CONTROL_PREFIXES the tokenizer split them on the `:` into a field token, and since
  // `bucket`/`agg`/`value_field`/`series`/`stats` are fields on no entity, the editor
  // underlined a perfectly valid chart query as unknown.
  test("downsample and stats controls are control tokens, not fields", () => {
    const query =
      "in:flows time:last_30d bucket:5m agg:avg value_field:bytes_total series:app limit:100"
    const result = tokenize(query, query.length)

    for (const control of ["bucket:", "agg:", "value_field:", "series:"]) {
      expect(result.tokens.some(token => token.kind === "control" && token.text === control)).toBe(
        true,
      )
    }

    for (const notAField of ["bucket", "agg", "value_field", "series"]) {
      expect(result.tokens.some(token => token.kind === "field" && token.text === notAField)).toBe(
        false,
      )
    }

    const stats = tokenize("in:flows stats:sum(bytes_total)", "in:flows stats:sum(bytes_total)".length)
    expect(stats.tokens).toContainEqual({start: 9, end: 15, kind: "control", text: "stats:"})
  })

  // `value_field:` / `series:` take a field name, so completion after them must offer the
  // entity's fields rather than free-text values.
  test("value_field: and series: remainders are field tokens", () => {
    const query = "in:flows bucket:5m agg:sum value_field:bytes_total series:app"
    const result = tokenize(query, query.length)

    const at = (text, kind) => ({
      start: query.indexOf(text),
      end: query.indexOf(text) + text.length,
      kind,
      text,
    })

    expect(result.tokens).toContainEqual(at("bytes_total", "field"))
    expect(result.tokens).toContainEqual(at("app", "field"))
    // bucket:/agg: take literals, so their remainders stay values.
    expect(result.tokens).toContainEqual(at("5m", "value"))
    expect(result.tokens).toContainEqual(at("sum", "value"))
  })

  test("metadata.<key> is a single field token, value follows the colon", () => {
    const query = 'in:devices metadata.gateway_id:"gateway-platform" include_inactive:true'
    const result = tokenize(query, query.length)

    expect(result.tokens).toContainEqual({start: 11, end: 30, kind: "field", text: "metadata.gateway_id"})
    expect(result.tokens).toContainEqual({start: 30, end: 31, kind: "op", text: ":"})
    expect(result.tokens).toContainEqual({start: 31, end: 49, kind: "value", text: '"gateway-platform"'})
  })
})

describe("JSONB key validation", () => {
  test("isValidJsonbKey mirrors the engine rule", () => {
    expect(isValidJsonbKey("gateway_id")).toBe(true)
    expect(isValidJsonbKey("Owner-1")).toBe(true)
    expect(isValidJsonbKey("a".repeat(64))).toBe(true)

    expect(isValidJsonbKey("")).toBe(false)
    expect(isValidJsonbKey("a".repeat(65))).toBe(false)
    expect(isValidJsonbKey("bad key")).toBe(false)
    expect(isValidJsonbKey("bad!")).toBe(false)
    expect(isValidJsonbKey("nested.key")).toBe(false)
  })

  test("isDynamicKeyField accepts metadata./tags. with valid keys", () => {
    expect(isDynamicKeyField("metadata.gateway_id")).toBe(true)
    expect(isDynamicKeyField("tags.owner")).toBe(true)
  })

  test("isDynamicKeyField rejects malformed keys and unsupported prefixes", () => {
    expect(isDynamicKeyField("metadata.")).toBe(false)
    expect(isDynamicKeyField("metadata.bad key")).toBe(false)
    expect(isDynamicKeyField("metadata.a.b")).toBe(false)
    expect(isDynamicKeyField("labels.team")).toBe(false)
    expect(isDynamicKeyField("hostname")).toBe(false)
    expect(isDynamicKeyField(".gateway_id")).toBe(false)
  })
})

describe("negated field names", () => {
  test("baseFieldName strips one leading ! like the engine", () => {
    expect(baseFieldName("!discovery_sources")).toBe("discovery_sources")
    expect(baseFieldName("discovery_sources")).toBe("discovery_sources")
    expect(baseFieldName("!is_active")).toBe("is_active")
  })

  test("baseFieldName strips exactly one !, matching strip_prefix semantics", () => {
    expect(baseFieldName("!!hostname")).toBe("!hostname")
    expect(baseFieldName("!")).toBe("")
    expect(baseFieldName("")).toBe("")
  })
})
