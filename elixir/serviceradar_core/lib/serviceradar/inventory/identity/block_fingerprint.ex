defmodule ServiceRadar.Inventory.Identity.BlockFingerprint do
  @moduledoc """
  The evidence fingerprint of a component the scheduled reconciliation blocks
  (add-source-id-succession D9).

  `DuplicateSweep` blocks some components on every run: a transitive component it will not
  flatten, or a pair a merge guard refuses. Without a record of the evidence it decided on, it
  re-attempted and re-recorded each of them every run, so a decision's occurrence count
  measured runs instead of evidence changes. The sweep stores the fingerprint in the decision's
  evidence (`"fingerprint"`) and skips a component whose fingerprint is unchanged.

  The fingerprint covers every input the blocking decision reads:

    * the reconciliation rule version (`rule_version/0`);
    * the sorted device set and, when the outcome depends on the merge direction, the survivor;
    * the evidence that joined the component;
    * each device's live and archived identifier rows of the merge identifier types, with the
      source id their metadata names;
    * each device's tombstone state, agent id, identity state and identity source;
    * each device's registered interface MACs;
    * the distinct assertions within the set.

  That is more than the identifiers, because the guards read more than the identifiers. The
  agent guard reads the device's `agent_id` column; the provisional-identity guard reads the
  device's identity metadata and is the one guard whose outcome depends on direction; the MAC
  guard reads the registered interface MACs. An input left out could change the outcome without
  changing the fingerprint, and the component would stay blocked on evidence that no longer
  holds.

  A recorded fingerprint is trusted only for a bounded time after the decision
  (`recorded/2`). After that the component is evaluated again whether or not it changed, which
  bounds the cost of a missed input or of a change between the read and the attempt.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceInterfaceMac
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Repo

  # Bump on every change to what decides a block: the classification in `DuplicateSweep`,
  # `MergePolicy`, the guards of `MergeEngine.merge_devices/3`, `SourceAuthorityGuard` and
  # `AliasGuard`. A new version changes every fingerprint, so every blocked component is
  # evaluated again once after the release that changes the rules.
  @rule_version 1

  @db_prefix "platform"
  @archive_table "device_identifier_archive"
  @lookup_chunk 1_000

  @type component :: %{
          required(:device_ids) => [String.t()],
          optional(:evidence) => [map()]
        }

  @type inputs :: %{
          identifiers: %{String.t() => [list()]},
          devices: %{String.t() => map()},
          interface_macs: %{String.t() => [String.t()]},
          assertions: MapSet.t({String.t(), String.t()})
        }

  @doc "The current reconciliation rule version."
  @spec rule_version() :: pos_integer()
  def rule_version, do: @rule_version

  @doc """
  Reads the fingerprint inputs of `device_ids` in one pass. Raises when a read fails; the
  caller then attempts its components as if nothing were recorded.
  """
  @spec load([String.t()]) :: inputs()
  def load(device_ids) when is_list(device_ids) do
    ids = device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    %{
      identifiers: identifier_rows(ids),
      devices: device_rows(ids),
      interface_macs: interface_macs(ids),
      assertions: Deduplication.asserted_distinct_pairs(ids)
    }
  end

  @doc """
  Whether a merge between `device_ids` depends on its direction: the provisional-identity guard
  refuses a provisional topology sighting as the survivor of a corroborated device, and is the
  only guard that reads the direction. The survivor is then part of the fingerprint.
  """
  @spec directional?([String.t()], inputs()) :: boolean()
  def directional?(device_ids, %{devices: devices}) do
    Enum.any?(device_ids, &match?(%{provisional?: true}, Map.get(devices, &1)))
  end

  @doc """
  The fingerprint of `component` over `inputs`. `opts`: `:survivor`, for a directional merge
  (`directional?/2`), and `:rule_version`, which tests use to stand for a new release.
  """
  @spec fingerprint(component(), inputs(), keyword()) :: String.t()
  def fingerprint(%{device_ids: device_ids} = component, inputs, opts \\ []) do
    ids = device_ids |> Enum.uniq() |> Enum.sort()

    material = [
      "serviceradar:identity-block",
      Keyword.get(opts, :rule_version, @rule_version),
      ids,
      Keyword.get(opts, :survivor),
      evidence_material(Map.get(component, :evidence) || []),
      Enum.flat_map(ids, &Map.get(inputs.identifiers, &1, [])),
      Enum.map(ids, &device_material(&1, inputs.devices)),
      Enum.flat_map(ids, fn id -> Enum.map(Map.get(inputs.interface_macs, id, []), &[id, &1]) end),
      assertion_material(ids, inputs.assertions)
    ]

    :sha256 |> :crypto.hash(Jason.encode!(material)) |> Base.encode16(case: :lower)
  end

  @doc """
  The fingerprints recorded in the evidence of the decisions `decision_keys` names, by key,
  for the decisions made within the last `recheck_seconds`. An older decision is left out, so
  its component is evaluated again.
  """
  @spec recorded([String.t()], non_neg_integer()) :: %{String.t() => String.t()}
  def recorded(decision_keys, recheck_seconds)
      when is_list(decision_keys) and is_integer(recheck_seconds) do
    cutoff = DateTime.shift(DateTime.utc_now(), second: -recheck_seconds)

    decision_keys
    |> Enum.uniq()
    |> Enum.chunk_every(@lookup_chunk)
    |> Enum.flat_map(fn keys ->
      Repo.all(
        from(d in "identity_decisions",
          where: d.decision_key in ^keys and d.last_decided_at > ^cutoff,
          where: not is_nil(fragment("?->>'fingerprint'", d.evidence)),
          select: {d.decision_key, fragment("?->>'fingerprint'", d.evidence)}
        ),
        prefix: @db_prefix
      )
    end)
    |> Map.new()
  end

  defp evidence_material(evidence) do
    evidence
    |> Enum.map(fn entry ->
      [
        scalar(Map.get(entry, :partition)),
        scalar(Map.get(entry, :type)),
        scalar(Map.get(entry, :value)),
        entry |> Map.get(:device_ids, []) |> Enum.sort()
      ]
    end)
    |> Enum.sort()
  end

  defp device_material(uid, devices) do
    case Map.get(devices, uid) do
      nil ->
        [uid, "missing"]

      device ->
        [uid, device.deleted?, device.agent_id, device.identity_state, device.identity_source]
    end
  end

  defp assertion_material(ids, assertions) do
    assertions
    |> Enum.filter(fn {a, b} -> a in ids and b in ids end)
    |> Enum.map(&Tuple.to_list/1)
    |> Enum.sort()
  end

  # The live rows and the archived rows of every merge identifier type, as
  # `[state, type, value, partition, source id]` lists by device. The source id is the one the
  # source-authority guard groups by.
  defp identifier_rows([]), do: %{}

  defp identifier_rows(ids) do
    types = Ids.identifier_priority()

    live =
      Repo.all(
        from(identifier in DeviceIdentifier,
          where: identifier.device_id in ^ids and identifier.identifier_type in ^types,
          select:
            {identifier.device_id, identifier.identifier_type, identifier.identifier_value,
             identifier.partition, identifier.metadata}
        )
      )

    archived =
      Repo.all(
        from(archived in @archive_table,
          where:
            archived.device_id in ^ids and
              archived.identifier_type in ^Enum.map(types, &Atom.to_string/1),
          select:
            {archived.device_id, archived.identifier_type, archived.identifier_value,
             archived.partition, archived.metadata}
        ),
        prefix: @db_prefix
      )

    (Enum.map(live, &identifier_row(&1, "live")) ++
       Enum.map(archived, &identifier_row(&1, "archived")))
    |> Enum.sort()
    |> Enum.group_by(&hd/1, &tl/1)
  end

  defp identifier_row({device_id, type, value, partition, metadata}, state) do
    [device_id, state, scalar(type), scalar(value), scalar(partition), source_id(metadata)]
  end

  defp source_id(%{"sync_service_id" => id}), do: scalar(id)
  defp source_id(_metadata), do: nil

  defp device_rows([]), do: %{}

  defp device_rows(ids) do
    from(d in Device,
      where: d.uid in ^ids,
      select: {d.uid, d.deleted_at, d.agent_id, d.metadata}
    )
    |> Repo.all()
    |> Map.new(fn {uid, deleted_at, agent_id, metadata} ->
      metadata = metadata || %{}

      {uid,
       %{
         deleted?: not is_nil(deleted_at),
         agent_id: agent_id(agent_id),
         identity_state: scalar(metadata["identity_state"]),
         identity_source: scalar(metadata["identity_source"]),
         provisional?: MergeEngine.provisional_topology_sighting?(metadata)
       }}
    end)
  end

  # The agent guard trims the column and ignores a blank one.
  defp agent_id(agent_id) when is_binary(agent_id) do
    case String.trim(agent_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp agent_id(_agent_id), do: nil

  defp interface_macs([]), do: %{}

  defp interface_macs(ids) do
    from(m in DeviceInterfaceMac, where: m.device_id in ^ids, select: {m.device_id, m.mac})
    |> Repo.all()
    |> Enum.sort()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp scalar(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: inspect(value)
end
