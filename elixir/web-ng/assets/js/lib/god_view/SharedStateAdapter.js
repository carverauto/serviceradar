export default class SharedStateAdapter {
  constructor(state) {
    this._state = state

    return new Proxy(this, {
      get(target, prop, receiver) {
        if (prop in target) return Reflect.get(target, prop, receiver)
        return state[prop]
      },
      set(target, prop, value, receiver) {
        if (prop in target) return Reflect.set(target, prop, value, receiver)
        state[prop] = value
        return true
      },
      has(target, prop) {
        return prop in target || prop in state
      },
    })
  }
}
