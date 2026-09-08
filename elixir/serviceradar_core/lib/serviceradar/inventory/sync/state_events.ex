defmodule ServiceRadar.Inventory.Sync.StateEvents do
  @moduledoc "Device state transition events and identity-cache invalidation for sync ingestion."

  import Ecto.Query

  alias ServiceRadar.EventWriter.StateChangePublisher
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  require Logger

  # add-causal-engine (Decision 1): capture prior device availability/managed
  # state BEFORE the bulk upsert so transitions can be published to
  # signals.state.ocsf_devices afterward. Gated behind the feed flag so disabled
  # deployments incur no extra read; best-effort (never affects ingestion).
  def previous_device_states(device_records) do
    if StateChangePublisher.enabled?() do
      uids =
        device_records
        |> Enum.map(&Map.get(&1, :uid))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case uids do
        [] ->
          %{}

        uids ->
          from(d in Device,
            where: d.uid in ^uids,
            select: {d.uid, d.is_available, d.is_managed}
          )
          |> Repo.all()
          |> Map.new(fn {uid, available, managed} ->
            {uid, %{is_available: available, is_managed: managed}}
          end)
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  def publish_device_state_transitions(_records, previous, _remap) when map_size(previous) == 0,
    do: :ok

  def publish_device_state_transitions(device_records, previous, remap) do
    Enum.each(device_records, fn record ->
      original_uid = Map.get(record, :uid)
      final_uid = Map.get(remap, original_uid, original_uid)
      prior = Map.get(previous, original_uid)

      if is_map(prior) and is_binary(final_uid) do
        maybe_publish_device_field(
          final_uid,
          "is_available",
          prior.is_available,
          Map.get(record, :is_available)
        )

        maybe_publish_device_field(
          final_uid,
          "is_managed",
          prior.is_managed,
          Map.get(record, :is_managed)
        )
      end
    end)

    :ok
  rescue
    error ->
      Logger.warning("state-change publish (ocsf_devices) failed: #{Exception.message(error)}")
      :ok
  end

  # The device upsert COALESCEs a nil incoming value (keeping the stored one), so
  # a transition only occurs when the incoming value is non-nil and differs.
  defp maybe_publish_device_field(_uid, _field, _old, nil), do: :ok
  defp maybe_publish_device_field(_uid, _field, old, new) when old == new, do: :ok

  defp maybe_publish_device_field(uid, field, old, new) do
    StateChangePublisher.publish_transition(
      "ocsf_devices",
      uid,
      field: field,
      old: old,
      new: new,
      entity_type: "device"
    )
  end

  def invalidate_identity_cache_for_device_records(records) do
    records
    |> Enum.map(&Map.get(&1, :ip))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.each(&IdentityCache.delete/1)
  end

  def invalidate_identity_cache_for_identifier_records(records) do
    records
    |> Enum.filter(&(&1.identifier_type in [:ip, "ip"]))
    |> Enum.map(& &1.identifier_value)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.each(&IdentityCache.delete/1)
  end
end
