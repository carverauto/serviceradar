/** Watch identity for a bitmap descriptor. Prefix source versions are frame freshness, not capability. */
export function capabilityIdentity(query) {
  if (!query || typeof query !== "object") return query ?? null
  const tags = query.prefix_tags
  if (!tags || typeof tags !== "object" || !Array.isArray(tags.sources)) return query
  return {
    ...query,
    prefix_tags: {
      ...tags,
      sources: tags.sources.map(source => {
        if (!source || typeof source !== "object") return source
        const {version: _version, ...identity} = source
        return identity
      }),
    },
  }
}
