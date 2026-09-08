export function yGridTicks(scale, count = 4) {
  if (!scale || typeof scale !== "function") return []

  const rawTicks =
    typeof scale.ticks === "function"
      ? scale.ticks(count)
      : Array.isArray(scale.domain?.())
        ? scale.domain()
        : []

  return rawTicks.filter((tick) => {
    const y = scale(tick)
    return Number.isFinite(Number(y))
  })
}
