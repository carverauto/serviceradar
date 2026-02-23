export function bindApi(context, methods) {
  return Object.fromEntries(
    Object.entries(methods)
      .filter(([, method]) => typeof method === "function")
      .map(([name, method]) => [name, method.bind(context)]),
  )
}

export function createStateBackedContext(state, deps = {}, stateKeys = []) {
  const context = {...deps, state, deps}

  for (const key of stateKeys) {
    Object.defineProperty(context, key, {
      configurable: true,
      enumerable: true,
      get() {
        return state[key]
      },
      set(value) {
        state[key] = value
      },
    })
  }

  return context
}
