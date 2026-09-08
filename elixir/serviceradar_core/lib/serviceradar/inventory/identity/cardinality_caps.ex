defmodule ServiceRadar.Inventory.Identity.CardinalityCaps do
  @moduledoc """
  Per-(device, identifier_type) cardinality caps with supersede-by-last_seen.

  A device legitimately accumulates identifiers over time, but unbounded
  accumulation is how the identifier table reached 12M rows. After writes,
  devices that exceed the configured cap for a type have their
  least-recently-seen identifiers beyond the cap retired. Retirements are
  logged with their values and counted in telemetry — never a silent delete.

  Caps are configurable:

      config :serviceradar, ServiceRadar.Inventory.Identity.CardinalityCaps,
        mac: 64,
        default: 8
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo

  require Logger

  @default_caps %{mac: 64, hardware_serial: 1, default: 8}

  @doc "The configured cap for an identifier type."
  @spec cap_for(atom()) :: pos_integer()
  def cap_for(identifier_type) do
    config = Application.get_env(:serviceradar, __MODULE__, [])

    Keyword.get(config, identifier_type) ||
      Keyword.get(config, :default) ||
      Map.get(@default_caps, identifier_type, @default_caps.default)
  end

  @doc """
  Enforce caps for the given `{device_id, identifier_type}` pairs.

  Intended to run after identifier writes with the pairs that were touched;
  one query per distinct type finds devices over cap, one batched delete
  per device retires the overflow (oldest `last_seen` first; `verified`
  identifiers are never retired).
  """
  @spec enforce([{String.t(), atom()}]) :: :ok
  def enforce(pairs) when is_list(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.group_by(fn {_device_id, type} -> type end, fn {device_id, _} -> device_id end)
    |> Enum.each(fn {type, device_ids} ->
      enforce_type(type, Enum.uniq(device_ids), cap_for(type))
    end)

    :ok
  rescue
    e ->
      Logger.warning("Identifier cardinality enforcement failed: #{inspect(e)}")
      :ok
  end

  defp enforce_type(type, device_ids, cap) do
    type_string = to_string(type)

    over_cap =
      Repo.all(
        from(di in DeviceIdentifier,
          where: di.device_id in ^device_ids and di.identifier_type == ^type_string,
          group_by: di.device_id,
          having: count(di.id) > ^cap,
          select: di.device_id
        )
      )

    Enum.each(over_cap, fn device_id -> retire_overflow(device_id, type_string, cap) end)
  end

  defp retire_overflow(device_id, type_string, cap) do
    keep_ids =
      Repo.all(
        from(di in DeviceIdentifier,
          where:
            di.device_id == ^device_id and di.identifier_type == ^type_string and
              di.verified == false,
          order_by: [desc: di.last_seen, desc: di.id],
          limit: ^cap,
          select: di.id
        )
      )

    # The delete and the fence bump go in one transaction. Retiring identifiers
    # changes which identifiers a device owns, and a crash between the two
    # statements would leave the device's composition changed with its revision
    # unmoved -- a fence that failed open, which is the one direction that matters.
    {:ok, {retired_count, retired}} =
      Repo.transaction(fn ->
        {count, values} =
          Repo.delete_all(
            from(di in DeviceIdentifier,
              where:
                di.device_id == ^device_id and di.identifier_type == ^type_string and
                  di.verified == false and
                  di.id not in ^keep_ids,
              select: di.identifier_value
            )
          )

        if count > 0, do: bump_identity_revision(device_id)

        {count, values}
      end)

    if retired_count > 0 do
      Logger.info(
        "Retired #{retired_count} #{type_string} identifier(s) over cap #{cap} on " <>
          "#{device_id}: #{inspect(retired || [], limit: 20)}"
      )

      :telemetry.execute(
        [:serviceradar, :identity_reconciler, :identifier, :retired],
        %{count: retired_count},
        %{identifier_type: type_string, device_id: device_id, cap: cap}
      )
    end
  end

  # Raw SQL rather than the Ash action because enforce/1 takes no actor and this
  # module already works at the Repo level. The expression form also cannot lose a
  # concurrent increment, and it is one statement inside the caller's transaction.
  #
  # Guarded by the caller on retired_count > 0, so a device that is merely at its
  # cap -- the overwhelmingly common case, since enforce/1 runs after every
  # identifier write -- never moves its revision.
  defp bump_identity_revision(device_id) do
    Repo.query!(
      "UPDATE platform.ocsf_devices SET identity_revision = identity_revision + 1 WHERE uid = $1",
      [device_id]
    )
  end
end
