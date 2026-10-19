defmodule ServiceRadar.Inventory.Availability.SyncEvidence do
  @moduledoc """
  Availability evidence for updates written by `ServiceRadar.Inventory.SyncIngestor`.

  After the sync write lands, each written update is offered to an *observation*
  function together with the device uid it was written to. The function returns the
  evidence the update carries (a `ServiceRadar.Inventory.Availability` submission
  without `:device_uid`) or `nil` when it carries none.

  In-process ingestors that own a source (Wi-Fi map, hypervisor, plugin discovery) pass
  their own observation as the `:availability_evidence` option, because only they know
  whether a status was reported or `is_available` was defaulted. Every other update gets
  `default_observation/1`, which treats only the mapper's sighting as evidence: a sync
  payload's `is_available` is a plain boolean that cannot say "no opinion" (design,
  Go readers).
  """

  alias ServiceRadar.Inventory.Availability

  @type observation :: (map() -> map() | nil)

  @doc "Records the evidence `observe` finds in written `{update, device_uid}` pairs."
  @spec capture([{map(), String.t() | nil}], observation()) :: :ok
  def capture(resolved_updates, observe) do
    resolved_updates
    |> Enum.flat_map(fn
      {update, uid} when is_binary(uid) and uid != "" ->
        case observe.(update) do
          %{} = submission -> [Map.put(submission, :device_uid, uid)]
          nil -> []
        end

      _unresolved ->
        []
    end)
    |> Availability.capture()
  end

  @doc """
  The observation for updates whose source registers none of its own: a mapper
  sighting is `passive_observation` evidence that the device is up, relayed by the
  agent that ran the mapper. The mapper only ever reports devices it saw.
  """
  @spec default_observation(map()) :: map() | nil
  def default_observation(%{source: "mapper", is_available: true} = update) do
    %{
      source_kind: "mapper",
      reporter_agent_id: Map.get(update, :agent_id),
      state: :up,
      observed_at: observed_at(update)
    }
  end

  def default_observation(_update), do: nil

  @doc "When a normalized update says it was observed, or now."
  @spec observed_at(map()) :: DateTime.t()
  def observed_at(update) do
    Map.get(update, :timestamp) || Map.get(update, :last_seen_time) || DateTime.utc_now()
  end
end
