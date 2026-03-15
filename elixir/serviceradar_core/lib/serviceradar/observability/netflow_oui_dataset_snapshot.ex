defmodule ServiceRadar.Observability.NetflowOuiDatasetSnapshot do
  @moduledoc """
  Snapshot metadata for IEEE OUI datasets used by flow enrichment.
  """

  use ServiceRadar.Observability.NetflowDatasetSnapshotResource,
    table: "netflow_oui_dataset_snapshots"
end
