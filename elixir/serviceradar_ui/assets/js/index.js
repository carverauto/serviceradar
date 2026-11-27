import {SrDialog} from "./hooks/dialog.js"
import {SrSparkline} from "./hooks/sparkline.js"
import {SrTimeseries} from "./hooks/timeseries.js"
import {SrWorldMap} from "./hooks/world_map.js"

// Register with the LiveSocket: `hooks: {...hooks, ...appHooks}`.
export const hooks = {
  SrDialog,
  SrSparkline,
  SrTimeseries,
  SrWorldMap,
}

export {SrDialog, SrSparkline, SrTimeseries, SrWorldMap}
