defmodule ServiceRadarNVR.MemberStatus do
  @moduledoc """
  Answer for `GET /v1/status`: one observation of this member, not a reservation.

  Reports the provisioned storage UUID, the recovery gate's state and pinned
  generation, the block ledger's state (`ready`, `rebuilding`, `mismatch` or
  `unavailable`), capacity measurements when the ledger is ready or mismatched,
  whether the member's one archive slot is busy, its recording session limit and
  the release version. A closed gate or an unbuilt ledger is reported, not refused.
  """

  alias ServiceRadarNVR.Capacity
  alias ServiceRadarRecordingControl.RecoveryGate

  def report(config) do
    {inventory, capacity} = capacity()

    %{
      version: 1,
      storage_id: config.storage_id,
      recovery: %{state: gate_state(config.recovery_gate), generation: generation(config.recovery_gate)},
      inventory: inventory,
      capacity: capacity,
      max_sessions: config.max_sessions,
      archive_busy: archive_busy?(),
      release: to_string(Application.spec(:serviceradar_nvr, :vsn))
    }
  end

  defp capacity do
    case Capacity.status() do
      {:ok, usage} ->
        {Atom.to_string(usage.inventory),
         Map.take(usage, [
           :used_bytes,
           :max_spool_bytes,
           :available_bytes,
           :reserve_bytes,
           :reserved_bytes,
           :reservations,
           :blocks,
           :max_blocks
         ])}

      {:error, :nvr_inventory_rebuilding} ->
        {"rebuilding", nil}

      {:error, _} ->
        {"unavailable", nil}
    end
  catch
    :exit, _ -> {"unavailable", nil}
  end

  defp gate_state(gate) do
    case RecoveryGate.check(gate) do
      :ok -> "ready"
      _ -> "closed"
    end
  end

  defp generation(%{generation: generation}), do: generation
  defp generation(_gate), do: nil

  defp archive_busy? do
    Task.Supervisor.children(ServiceRadarNVR.ArchiveTasks) != []
  catch
    :exit, _ -> false
  end
end
