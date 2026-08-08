defmodule ServiceRadar.ColdTier do
  @moduledoc """
  Tiered telemetry cold-storage domain (OpenSpec add-tiered-telemetry-offload).

  Owns the export manifest and tier-boundary state for the offload pipeline.
  The pipeline itself (exporter, retention fence, pruning) lives alongside in
  `ServiceRadar.ColdTier.*` modules; all behavior is inert unless
  deployment-supplied cold-tier configuration is present
  (see `ServiceRadar.ColdTier.Registry.enabled?/0`).
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.ColdTier.ChunkExport
    resource ServiceRadar.ColdTier.Boundary
  end
end
