import {godViewLifecycleBootstrapEventFilterMethods} from "./lifecycle_bootstrap_event_filter_methods"
import {godViewLifecycleBootstrapEventZoomMethods} from "./lifecycle_bootstrap_event_zoom_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {godViewLifecycleBootstrapEventResetViewMethods} from "./lifecycle_bootstrap_event_reset_view_methods"

const godViewLifecycleBootstrapEventCoreMethods = {
  registerLifecycleEvents() {
    this.registerFilterEvent()
    this.registerZoomModeEvent()
    this.registerLayerEvents()
    this.registerResetViewEvent()
  },
}

export const godViewLifecycleBootstrapEventMethods = Object.assign(
  {},
  godViewLifecycleBootstrapEventCoreMethods,
  godViewLifecycleBootstrapEventFilterMethods,
  godViewLifecycleBootstrapEventZoomMethods,
  godViewLifecycleBootstrapEventLayerMethods,
  godViewLifecycleBootstrapEventResetViewMethods,
)
