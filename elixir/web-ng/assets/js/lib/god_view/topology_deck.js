import {Deck} from "@deck.gl/core"

// Deck finalizes layers, but leaves its device and Luma's per-device buffer
// pool alive. Topology owns one device per canvas, including during creation.
export class TopologyDeck extends Deck {
  constructor(props) {
    const lifetime = {disposed: false, device: null}
    const adapters = props.deviceProps.adapters.map(adapter => Object.assign(Object.create(adapter), {
      async create(deviceProps) {
        const created = await adapter.create(deviceProps)
        lifetime.device = created
        if (lifetime.disposed) {
          created.destroy()
          lifetime.device = null
          throw new Error("GPU device closed during creation")
        }
        return created
      },
    }))
    try {
      super({...props, deviceProps: {...props.deviceProps, adapters, _reuseDevices: false}})
      this.topologyLifetime = lifetime
    } catch (error) {
      lifetime.disposed = true
      lifetime.device?.destroy()
      throw error
    }
  }

  finalize() {
    const lifetime = this.topologyLifetime
    if (lifetime?.disposed) return
    if (lifetime) lifetime.disposed = true
    const device = lifetime?.device
    try {
      if (device && !device.isLost) device.submit()
    } finally {
      try {super.finalize()} finally {
        if (device) {
          const completion = device.handle?.queue.onSubmittedWorkDone()
          if (completion) void completion.then(() => device.destroy(), () => device.destroy())
          else device.destroy()
        }
      }
    }
  }
}
