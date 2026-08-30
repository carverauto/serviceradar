defmodule ServiceRadar.Inventory.DeviceSNMPFactWriter do
  @moduledoc """
  Records the latest value of every SNMP reading against the device it came from.

  This runs alongside the timeseries write, not instead of it. Numeric readings
  continue to `timeseries_metrics` exactly as before; this adds the current-state
  surface beside it, and exists because `timeseries_metrics.value` is a
  non-nullable float while `string` is a legal SNMP data type. A software
  version, a node role, a service name can be polled successfully and then have
  nowhere to land.

  Everything needed is already on the decoded metric row:

    * `metadata["oid"]` is the *instance* OID - the configured OID with the walk
      index already appended (`instanceOID/2` in `go/pkg/agent/push_loop_snmp.go`)
      - so it is unique per walked row without any further disambiguation.
    * `metadata["raw_value"]` carries the value as a string, which is the only
      representation that survives for a string-typed OID.
    * `metadata["data_type"]` is the OID's declared type, and
      `metadata["oid_index"]` is the raw walk index - empty for a scalar get.

  The index is taken from its own field rather than recovered from
  `tags["interface_uid"]`, which looks equivalent and is not: for a scalar get on
  a non-interface OID whose last arc is a positive integer, `ifIndexForSNMPPoint`
  falls through to `parseIfIndexFromOID` and yields `"ifindex:<last arc>"`. That
  would record an index for a reading that has none - silently, stably, and
  wrongly.
    * `device_id` is the canonical device uid, resolved upstream by
      `backfill_device_ids/1`.

  A reading whose device could not be resolved is skipped before it reaches the
  database. `device_uid` is a foreign key to `ocsf_devices.uid`, so such a row
  can never be written; rows are upserted individually, so the failure would be
  contained either way, but on a fleet with unresolved devices it would be a
  guaranteed-failing round trip for every such reading on every poll.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceSNMPFact
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query
  require Logger

  @snmp_metric_type "snmp"

  @doc """
  Writes one fact per SNMP reading in the batch.

  Always returns `:ok`. Fact storage is a secondary surface: a failure here must
  not fail the timeseries write that the same batch is about to perform, because
  losing a metric point is worse than losing a snapshot row that the next poll
  will rewrite anyway.
  """
  @spec write_rows([map()]) :: :ok
  def write_rows(rows) when is_list(rows) do
    case snmp_facts(rows) do
      [] ->
        :ok

      facts ->
        actor = SystemActor.system(:device_snmp_fact_writer)

        facts
        |> attach_plugin_package_ids(actor)
        |> Enum.each(&upsert(&1, actor))
    end
  rescue
    error ->
      Logger.warning("device SNMP fact write failed", error: inspect(error))
      :ok
  end

  def write_rows(_rows), do: :ok

  # Deduplicates within the batch before writing. One drained batch can carry
  # several polls of the same OID; without this they would upsert over each
  # other in arbitrary order and could leave the older reading stored.
  defp snmp_facts(rows) do
    rows
    |> Enum.filter(&snmp_row?/1)
    |> Enum.map(&fact_attrs/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(&{&1.device_uid, &1.oid, &1.oid_index})
    |> Enum.map(fn {_key, candidates} -> Enum.max_by(candidates, & &1.collected_at, DateTime) end)
  end

  defp snmp_row?(%{metric_type: @snmp_metric_type} = row), do: is_binary(row[:device_id])
  defp snmp_row?(_row), do: false

  defp fact_attrs(row) do
    metadata = row[:metadata] || %{}
    oid = metadata |> Map.get("oid") |> trimmed()

    if oid == "" do
      nil
    else
      %{
        device_uid: row[:device_id],
        oid: oid,
        oid_index: metadata |> Map.get("oid_index") |> trimmed(),
        oid_name: row[:metric_name],
        data_type: data_type(metadata),
        value: value(metadata, row[:value]),
        snmp_profile_id: parse_uuid(metadata["snmp_profile_id"]),
        plugin_package_id: parse_uuid(metadata["plugin_package_id"]),
        collected_at: row[:timestamp] || DateTime.utc_now()
      }
    end
  end

  defp attach_plugin_package_ids(facts, actor) do
    profile_ids =
      facts
      |> Enum.map(& &1.snmp_profile_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    package_by_profile = plugin_package_ids(profile_ids, actor)

    Enum.map(facts, fn fact ->
      case {fact.plugin_package_id, Map.get(package_by_profile, fact.snmp_profile_id)} do
        {nil, package_id} -> Map.put(fact, :plugin_package_id, package_id)
        {_present, _} -> fact
      end
    end)
  end

  defp plugin_package_ids([], _actor), do: %{}

  defp plugin_package_ids(profile_ids, actor) do
    case SNMPProfile
         |> Ash.Query.filter(id in ^profile_ids)
         |> Ash.read(actor: actor) do
      {:ok, profiles} ->
        Map.new(profiles, fn profile -> {profile.id, profile.plugin_package_id} end)

      {:error, reason} ->
        Logger.warning("device SNMP fact profile lookup failed", error: inspect(reason))
        %{}
    end
  end

  defp parse_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_uuid(_value), do: nil

  # Prefers the declared type over the wire type. `raw_value_type` describes how
  # the value was encoded on the wire; `data_type` is what the OID was declared
  # as, which is what an operator reading this table is looking for.
  defp data_type(metadata) do
    case metadata |> Map.get("data_type") |> trimmed() do
      "" -> metadata |> Map.get("raw_value_type") |> trimmed() |> presence("unknown")
      declared -> declared
    end
  end

  # raw_value is the only representation that survives for a string OID; the
  # float is meaningless there. Falling back to the float keeps a numeric OID
  # readable when the producer sent no raw value.
  defp value(metadata, numeric) do
    case metadata |> Map.get("raw_value") |> trimmed() do
      "" -> numeric && to_string(numeric)
      raw -> raw
    end
  end

  defp upsert(attrs, actor) do
    DeviceSNMPFact
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _fact} ->
        :ok

      {:error, error} ->
        Logger.debug("device SNMP fact upsert rejected",
          device_uid: attrs.device_uid,
          oid: attrs.oid,
          error: inspect(error)
        )

        :ok
    end
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value
end
