// Offline scenario chips for the kit example. A chip issues an `srql.update`
// whose query names the scenario; the resolver answers with the matching
// fixture so the strip, banner and countdown follow with no live backend.
export function resolveFixture({query}) {
  if (typeof query !== "string") return undefined
  if (query.includes("scenario:mid-fault")) return "mid-fault"
  if (query.includes("scenario:steady")) return "steady"
  return undefined
}
