import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"
import {godViewLifecycleStreamPollingMethods} from "./lifecycle_stream_polling_methods"
import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

export const godViewLifecycleStreamMethods = Object.assign(
  {},
  godViewLifecycleStreamSnapshotMethods,
  godViewLifecycleStreamPollingMethods,
  godViewLifecycleStreamDecodeMethods,
)
