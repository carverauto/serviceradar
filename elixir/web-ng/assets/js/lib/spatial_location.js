/** Versioned Cartesian locations, independent of deck.gl and data transport.
 * A space id names the units, axes and zoom convention; version names its layout.
 * The caller supplies an authorized resource descriptor, never one from the URL.
 */
const legacyIdentityParams = {v: "map_v", type: "map_type", resource: "map_resource", space: "map_space", version: "map_version"}
const legacyParams = [...Object.values(legacyIdentityParams), "map_x", "map_y", "map_zoom"]
const locationParams = ["layout", "x", "y", "z"]

export function readPlanLocation(url, frame) {
  const params = new URL(url).searchParams
  const legacy = !locationParams.some(key => params.has(key))
  const keys = legacy ? legacyParams : locationParams
  if (!keys.some(key => params.has(key))) return null
  if (keys.some(key => params.getAll(key).length !== 1 || !params.get(key)?.trim() || params.get(key).length > 512)) {
    throw new Error("Invalid shared location")
  }
  // The authorized route supplies resource/space identity for compact links.
  // Continue validating those claims when opening an older expanded link.
  const location = legacy
    ? Object.fromEntries(Object.entries(legacyIdentityParams).map(([key, param]) => [key, params.get(param)]))
    : {v: 1, type: "plan", resource: frame.resource, space: frame.space, version: params.get("layout")}
  return validate({...location, v: Number(location.v),
    center: [Number(params.get(legacy ? "map_x" : "x")), Number(params.get(legacy ? "map_y" : "y"))],
    zoom: Number(params.get(legacy ? "map_zoom" : "z"))}, frame)
}

export function planLocationURL(url, {center, zoom}, frame) {
  const location = validate({v: 1, type: "plan", resource: frame.resource,
    space: frame.space, version: frame.version, center, zoom}, frame)
  const next = clearPlanLocation(url)
  next.searchParams.set("layout", location.version)
  next.searchParams.set("x", Number(center[0].toFixed(1)))
  next.searchParams.set("y", Number(center[1].toFixed(1)))
  next.searchParams.set("z", Number(zoom.toFixed(3)))
  return next
}

export function clearPlanLocation(url) {
  const next = new URL(url)
  for (const key of [...locationParams, ...legacyParams]) next.searchParams.delete(key)
  return next
}

function validate(location, frame) {
  if (!location || location.v !== 1 || location.type !== "plan" ||
      location.resource !== frame.resource || location.space !== frame.space) {
    throw new Error("This shared location belongs to a different map or coordinate space")
  }
  if (location.version !== frame.version) throw new Error("The shared layout is no longer available")
  const {center, zoom} = location
  if (!Array.isArray(center) || center.length !== 2 ||
      !center.every((value, axis) => Number.isFinite(value) && value >= frame.bounds[0][axis] && value <= frame.bounds[1][axis]) ||
      !Number.isFinite(zoom) || zoom < frame.minZoom || zoom > frame.maxZoom) {
    throw new Error("The shared location has invalid coordinates or zoom")
  }
  return {v: 1, type: "plan", resource: frame.resource, space: frame.space,
    version: frame.version, center: [...center], zoom}
}
