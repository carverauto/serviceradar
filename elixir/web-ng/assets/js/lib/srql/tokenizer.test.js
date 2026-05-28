import {describe, expect, test} from "vitest"

import {tokenize} from "./tokenizer.js"

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
})
