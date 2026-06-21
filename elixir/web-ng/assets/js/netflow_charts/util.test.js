import {describe, expect, it} from "vitest"

import {clientXToScaleX} from "./util"

describe("netflow tooltip geometry", () => {
  const rect = {left: 100, width: 500}
  const xScale = {range: () => [0, 356]}

  it("subtracts translated plot offsets before x-scale inversion", () => {
    expect(clientXToScaleX(154, rect, xScale, {xOffset: 44})).toBe(10)
    expect(clientXToScaleX(322, rect, xScale, {xOffset: 44})).toBe(178)
  })

  it("clamps to the actual x-scale range", () => {
    expect(clientXToScaleX(120, rect, xScale, {xOffset: 44})).toBe(0)
    expect(clientXToScaleX(600, rect, xScale, {xOffset: 44})).toBe(356)
  })
})
