defmodule ServiceRadar.ColdTier do
  @moduledoc """
  Tiered telemetry cold-storage domain (OpenSpec add-tiered-telemetry-offload).

  Owns the export manifest and tier-boundary state for the offload pipeline.
  The pipeline itself (exporter, retention fence, pruning) lives alongside in
  `ServiceRadar.ColdTier.*` modules. Archive activation and backend reporting
  follow `ServiceRadar.ColdTier.Config.state/0`; retention also preserves
  existing boundary residue while archival is disabled.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.ColdTier.ChunkExport
    resource ServiceRadar.ColdTier.Boundary
  end
end
