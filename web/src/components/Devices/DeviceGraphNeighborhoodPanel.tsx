/*
 * Device detail graph panel that shares graph data between the ReactFlow canvas
 * and the textual summary card.
 */
"use client";

import React from "react";
import { GitBranch, Layers } from "lucide-react";
import DeviceGraphCanvas from "./DeviceGraphCanvas";
import {
  DeviceGraphSummaryCard,
  useDeviceGraphNeighborhood,
} from "./DeviceGraphSummary";

type DeviceGraphNeighborhoodPanelProps = {
  deviceId: string;
  defaultCollectorOwnedOnly?: boolean;
};

const DeviceGraphNeighborhoodPanel: React.FC<
  DeviceGraphNeighborhoodPanelProps
> = ({ deviceId, defaultCollectorOwnedOnly = false }) => {
  const {
    graph,
    loading,
    error,
    collectorOwnedOnly,
    includeTopology,
    setCollectorOwnedOnly,
    setIncludeTopology,
  } = useDeviceGraphNeighborhood(deviceId, {
    defaultCollectorOwnedOnly,
    includeTopology: true,
  });

  return (
    <DeviceGraphSummaryCard
      deviceId={deviceId}
      graph={graph}
      loading={loading}
      error={error}
      collectorOwnedOnly={collectorOwnedOnly}
      includeTopology={includeTopology}
      onToggleCollectorOwnedOnly={() =>
        setCollectorOwnedOnly((prev) => !prev)
      }
    >
      <div className="mb-2 flex items-center justify-between px-1">
        <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
          <GitBranch className="h-4 w-4" />
          Neighborhood canvas
        </div>
        <button
          type="button"
          onClick={() => setIncludeTopology((prev) => !prev)}
          className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1 text-xs font-medium text-gray-800 dark:text-gray-100 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          <Layers className="h-4 w-4" />
          {includeTopology ? "Hide topology" : "Show topology"}
        </button>
      </div>
      <DeviceGraphCanvas
        deviceId={deviceId}
        graph={graph}
        collectorOwnedOnly={collectorOwnedOnly}
        includeTopology={includeTopology}
      />
    </DeviceGraphSummaryCard>
  );
};

export default DeviceGraphNeighborhoodPanel;
