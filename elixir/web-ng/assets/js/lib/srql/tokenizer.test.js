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

  test("where: places the cursor in a field slot", () => {
    const result = tokenize("in:devices where:", "in:devices where:".length)

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

  test("where followed by whitespace expects a field", () => {
    const result = tokenize("in:devices where ", "in:devices where ".length)

    expect(result.slot).toBe("field")
  })
})
