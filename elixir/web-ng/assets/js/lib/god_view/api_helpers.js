export function bindApi(context, methods) {
  return Object.fromEntries(
    Object.entries(methods)
      .filter(([, method]) => typeof method === "function")
      .map(([name, method]) => [name, method.bind(context)]),
  )
}
