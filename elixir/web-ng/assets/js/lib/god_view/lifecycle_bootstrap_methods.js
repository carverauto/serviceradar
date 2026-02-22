import {godViewLifecycleBootstrapChannelMethods} from "./lifecycle_bootstrap_channel_methods"
import {godViewLifecycleBootstrapCleanupMethods} from "./lifecycle_bootstrap_cleanup_methods"
import {godViewLifecycleBootstrapEventMethods} from "./lifecycle_bootstrap_event_methods"
import {godViewLifecycleBootstrapStateMethods} from "./lifecycle_bootstrap_state_methods"

export const godViewLifecycleBootstrapMethods = Object.assign(
  {},
  godViewLifecycleBootstrapStateMethods,
  godViewLifecycleBootstrapEventMethods,
  godViewLifecycleBootstrapChannelMethods,
  godViewLifecycleBootstrapCleanupMethods,
)
