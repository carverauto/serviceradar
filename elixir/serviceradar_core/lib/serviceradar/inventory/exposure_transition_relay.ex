defmodule ServiceRadar.Inventory.ExposureTransitionRelay do
  @moduledoc "Acknowledged JetStream publication of complete exposure transitions from their transactional outbox."

  alias ServiceRadar.Inventory.ExposureOutboxRelay

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def start_link(opts \\ []), do: ExposureOutboxRelay.start_link(__MODULE__, options(opts))
  def relay_once(opts \\ []), do: ExposureOutboxRelay.relay_once(options(opts))
  def default_max_bytes, do: 1_073_741_824
  defp stream_name, do: "EXPOSURE_TRANSITIONS"

  def subject(value) when is_binary(value),
    do: "vulnerability.assessment.transitions.#{:erlang.phash2(value, 16)}"

  @doc false
  def spec do
    %{
      table: "exposure_transition_outbox",
      routing_field: :device_uid,
      stream: stream_name(),
      subjects: ["vulnerability.assessment.transitions.>"],
      message_prefix: "exposure-transition",
      metrics: "exposure_transitions"
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
