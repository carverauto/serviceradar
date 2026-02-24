import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"
import {godViewLifecycleStreamPollingMethods} from "./lifecycle_stream_polling_methods"
import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"

export const godViewLifecycleStreamMethods = Object.assign(
  {},
  godViewLifecycleStreamSnapshotMethods,
  godViewLifecycleStreamPollingMethods,
  godViewLifecycleStreamDecodeMethods,
)
