defmodule ServiceRadarAgentGateway.EdgeRecordSpoolReport do
  @moduledoc """
  The edge-record spool health an agent reports in its hellos, as the gateway records it.

  The agent samples its spool afresh for every hello: the enrollment hello, the first
  control-stream hello, and each periodic control-stream heartbeat. The gateway records the
  sample in `ServiceRadar.AgentTracker` (`edge_record_spool`), which core's cluster health and
  edge pipeline readiness read (`ServiceRadar.Edge.PipelineReadiness`). An agent that predates
  the default-on sender reports nothing, which core shows as agent_upgrade_pending; a spool that
  did not open is spool_unavailable.
  """

  @fields [
    :available,
    :error,
    :health_available,
    :health_error,
    :wedged,
    :gap_sequences,
    :gap_count,
    :unresolved_count,
    :oldest_unresolved_age_seconds,
    :oldest_unresolved_age_known,
    :unresolved_bytes,
    :bytes_used,
    :budget_bytes,
    :admission_paused,
    :retained_legacy_bytes,
    :legacy_handoff_pending_records,
    :legacy_handoff_reason,
    :late_pending_records,
    :late_pending_reason
  ]

  @doc "The spool report a hello carries, or nil when it carries none."
  @spec from_hello(map() | nil) :: map() | nil
  def from_hello(%{edge_record_spool: %Monitoring.EdgeRecordSpoolStatus{} = spool}) do
    spool
    |> Map.take(@fields)
    |> Map.put(
      :generation_gaps,
      Enum.map(spool.generation_gaps, fn gap ->
        %{
          spool_generation_id: Base.encode16(gap.spool_generation_id, case: :lower),
          route_profile: gap.route_profile,
          traffic_class: gap.traffic_class,
          sequence: gap.sequence
        }
      end)
    )
  end

  def from_hello(_hello), do: nil
end
