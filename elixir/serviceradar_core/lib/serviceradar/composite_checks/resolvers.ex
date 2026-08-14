defmodule ServiceRadar.CompositeChecks.Resolvers do
  @moduledoc """
  Namespace for composite check input resolvers.

  Adding an input kind means adding a module here, a clause in
  `ServiceRadar.CompositeChecks.Validations.InputConfig`, and a clause in
  `ServiceRadar.CompositeChecks.Evaluation.resolve_inputs/5`. Rule structure,
  result storage, and the evaluator are unaffected — that is the extension seam.

  Every resolver is pure and takes already-loaded state, so the evaluation pass
  can batch-load a page of devices and resolve them in memory.
  """

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.CompositeChecks.Resolvers.VantagePoint

  @doc "Resolvers that ship, keyed by the input `kind` they serve."
  @spec kinds() :: %{atom() => module()}
  def kinds, do: %{vantage_point: VantagePoint, device_metadata: DeviceMetadata}
end
