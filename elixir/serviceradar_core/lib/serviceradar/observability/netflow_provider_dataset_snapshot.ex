defmodule ServiceRadar.Observability.NetflowProviderDatasetSnapshot do
  @moduledoc """
  Snapshot metadata for cloud-provider CIDR datasets used by flow enrichment.
  """

  use ServiceRadar.Observability.NetflowDatasetSnapshotResource,
    table: "netflow_provider_dataset_snapshots"
end
