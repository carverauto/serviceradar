export function createPlanView({layers = [], viewState = {}, controller = true} = {}) {
  return {
    views: [{type: "OrthographicView", controller}],
    viewState: {target: [0, 0, 0], zoom: 0, ...viewState},
    layers,
  }
}

export function planViewLayer(layer) {
  return layer
}
