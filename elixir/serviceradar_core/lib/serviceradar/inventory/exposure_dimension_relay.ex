defmodule ServiceRadar.Inventory.ExposureDimensionRelay do
  @moduledoc "Acknowledged JetStream publication of complete exposure dimensions from their transactional outbox."

  alias ServiceRadar.Inventory.ExposureOutboxRelay

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def start_link(opts \\ []), do: ExposureOutboxRelay.start_link(__MODULE__, options(opts))
  def relay_once(opts \\ []), do: ExposureOutboxRelay.relay_once(options(opts))
  def default_max_bytes, do: 1_073_741_824
  defp stream_name, do: "EXPOSURE_DIMENSIONS"
  def subject(value) when value in ["cve", "package"], do: "exposure.dimensions.#{value}"

  @doc false
  def spec do
    %{
      table: "exposure_dimension_outbox",
      routing_field: :kind,
      stream: stream_name(),
      subjects: ["exposure.dimensions.cve", "exposure.dimensions.package"],
      message_prefix: "exposure-dimension",
      metrics: "exposure_dimensions"
    }
  end

  defp options(opts) do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
    |> Keyword.put(:owner, __MODULE__)
    |> Keyword.put(:spec, spec())
  end
end
