defmodule ServiceRadar.Inventory.Identity.SourceAuthorityGuard do
  @moduledoc """
  Fail-closed guard for automatic merges across source-authoritative IDs.

  A MAC, IP, hostname, or transitive duplicate edge cannot authorize combining
  two non-empty, disjoint identity sets of one source-authoritative identifier
  type (`source_identifier_types/0`: the Armis device id and the NetBox device
  id) from the same source scope.

  The same rule governs resolution: an update carrying a source-authoritative
  identifier never resolves onto a record, through a shared MAC or any other
  identifier, when that record holds a different source-authoritative
  identifier in the same scope. The source-authoritative identifier decides,
  the shared identifier is evidence only, and the override is recorded
  (`source_mismatch?/3`, `record_overrides/1`).
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Repo

  require Ash.Query

  # Source-authoritative identifier types, with the key each is extracted under
  # (`Ids.extract_strong_identifiers/1`). Two different values of one type in one
  # scope are two different devices, whatever other evidence says. The scope is
  # the identifier partition, which is also the scope a value is unique in: Armis
  # partitions carry the sync source, and the NetBox device id carries its source
  # in the value.
  @source_identifiers [armis_device_id: :armis_id, netbox_device_id: :netbox_id]
  @source_identifier_types Keyword.keys(@source_identifiers)

  @typedoc """
  Source-authoritative identifiers per device, as `{identifier_type, partition, value}`
  triples.
  """
  @type held :: %{String.t() => MapSet.t({atom(), String.t(), String.t()})}

  @typedoc """
  A resolution that refused identifier matches on records holding a different
  source-authoritative identifier (`SourceIdentityDrift.build_source_override_conflict/1`).
  """
  @type override :: %{
          update: map(),
          ids: Ids.strong_identifiers(),
          device_uid: String.t(),
          overridden: [
            %{
              device_uid: String.t(),
              identifier_type: atom(),
              identifier_value: String.t(),
              source_ids: [String.t()]
            }
          ]
        }

  @doc "The source-authoritative identifier types, in identifier-priority order."
  @spec source_identifier_types() :: [atom()]
  def source_identifier_types, do: @source_identifier_types

  @doc """
  The source-authoritative identifiers an update carries, as `{identifier_type, value}`
  pairs.
  """
  @spec update_source_ids(Ids.strong_identifiers()) :: [{atom(), String.t()}]
  def update_source_ids(ids) do
    for {type, key} <- @source_identifiers,
        value = Ids.ids_get(ids, key),
        Ids.present_id?(value),
        do: {type, value}
  end

  @doc "True when the update carries a source-authoritative identifier."
  @spec carries_source_id?(Ids.strong_identifiers()) :: boolean()
  def carries_source_id?(ids), do: update_source_ids(ids) != []

  @doc """
  Claim the update's source-authoritative identifiers on `device_id` in `held`, so a later
  update in the same batch carrying a different one is refused that device.
  """
  @spec claim(held(), Ids.strong_identifiers(), String.t()) :: held()
  def claim(held, ids, device_id) do
    partition = Ids.ids_get_partition(ids)

    case update_source_ids(ids) do
      [] ->
        held

      pairs ->
        claims = MapSet.new(pairs, fn {type, value} -> {type, partition, value} end)
        Map.update(held, device_id, claims, &MapSet.union(&1, claims))
    end
  end

  @doc """
  The source-authoritative identifiers each of `device_ids` holds.
  """
  @spec held_source_ids([String.t()], term()) :: held()
  def held_source_ids(device_ids, actor) do
    case device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      device_ids ->
        query_opts = if actor, do: [actor: actor], else: []

        DeviceIdentifier
        |> Ash.Query.filter(
          device_id in ^device_ids and identifier_type in ^@source_identifier_types
        )
        |> Ash.Query.select([:device_id, :identifier_type, :identifier_value, :partition])
        |> Page.stream!(query_opts)
        |> Enum.group_by(
          & &1.device_id,
          &{identifier_type(&1.identifier_type), &1.partition, &1.identifier_value}
        )
        |> Map.new(fn {device_id, pairs} -> {device_id, MapSet.new(pairs)} end)
    end
  end

  @doc """
  True when an update carrying `ids` must not resolve onto `device_id`: for some
  source-authoritative identifier type the update carries, the device holds at least one
  value of that type in the update's scope (its identifier partition), and none of them is
  the update's.

  A device holding no source-authoritative identifier of that type is not a mismatch: a
  discovered record of the same device, found through its MAC, or a record of the same device
  from a different source, is what the source-authoritative identifier should attach to.
  """
  @spec source_mismatch?(Ids.strong_identifiers(), String.t(), held()) :: boolean()
  def source_mismatch?(ids, device_id, held) do
    partition = Ids.ids_get_partition(ids)

    Enum.any?(update_source_ids(ids), fn {type, value} ->
      scoped = held_values(held, device_id, type, partition)
      scoped != [] and value not in scoped
    end)
  end

  @doc """
  The source-authoritative identifiers `device_id` holds in the update's scope, of the types
  the update carries, sorted.
  """
  @spec scoped_source_ids(held(), String.t(), Ids.strong_identifiers()) :: [String.t()]
  def scoped_source_ids(held, device_id, ids) do
    partition = Ids.ids_get_partition(ids)

    ids
    |> update_source_ids()
    |> Enum.flat_map(fn {type, _value} -> held_values(held, device_id, type, partition) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp held_values(held, device_id, type, partition) do
    held
    |> Map.get(device_id, MapSet.new())
    |> Enum.flat_map(fn
      {^type, ^partition, value} -> [value]
      _other -> []
    end)
  end

  @doc """
  Record source-authoritative overrides: one telemetry event, one identity decision and one
  open `SourceIdentityConflict` row (category `source_authoritative_override`) per update, so
  an operator can review every identity the rule decided.
  """
  @spec record_overrides([override()]) :: :ok | {:error, term()}
  def record_overrides([]), do: :ok

  def record_overrides(overrides) when is_list(overrides) do
    # One row per open conflict key: a batch repeating an update records it once.
    overrides = Enum.uniq_by(overrides, &{&1.device_uid, update_source_ids(&1.ids)})

    _ = DecisionLog.record_many(Enum.map(overrides, &override_decision/1))

    overrides
    |> Enum.map(&SourceIdentityDrift.build_source_override_conflict/1)
    |> SourceIdentityDrift.record_conflicts()
  end

  defp override_decision(%{device_uid: device_uid, overridden: overridden} = override) do
    overridden_uids = overridden |> Enum.map(& &1.device_uid) |> Enum.uniq() |> Enum.sort()

    %{
      kind: :source_override,
      reason: "source_authoritative_identifier",
      device_uids: [device_uid | overridden_uids],
      source: "source_authority_guard",
      evidence: %{
        "source_identifiers" =>
          Map.new(update_source_ids(override.ids), fn {type, value} ->
            {Atom.to_string(type), value}
          end),
        "partition" => Ids.ids_get_partition(override.ids),
        "matched_identifiers" =>
          Enum.map(overridden, fn match ->
            %{
              "device_uid" => match.device_uid,
              "identifier_type" => match.identifier_type,
              "identifier_value" => match.identifier_value,
              "device_source_ids" => match.source_ids
            }
          end)
      }
    }
  end

  @spec conflict_details([String.t()], keyword()) :: map() | nil
  def conflict_details(device_ids, opts \\ []) when is_list(device_ids) do
    device_ids = device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if length(device_ids) < 2 do
      nil
    else
      device_ids
      |> identifier_rows(Keyword.get(opts, :lock, false))
      |> conflict_from_rows(device_ids)
    end
  end

  @spec ensure_merge_allowed([String.t()], keyword()) :: :ok | {:error, term()}
  def ensure_merge_allowed(device_ids, opts \\ []) do
    with :ok <- maybe_lock_ownership(device_ids, Keyword.get(opts, :lock, false)) do
      case conflict_details(device_ids, opts) do
        nil -> :ok
        details -> {:error, {:source_authority_conflict, details}}
      end
    end
  end

  @doc false
  def conflict_from_rows(rows, device_ids) when is_list(rows) and is_list(device_ids) do
    rows
    |> Enum.group_by(fn row ->
      {identifier_type(row.identifier_type), row.partition, source_id(row)}
    end)
    |> Enum.sort()
    |> Enum.find_value(fn {{type, partition, source_id}, scoped_rows} ->
      sets =
        Map.new(device_ids, fn device_id ->
          ids =
            scoped_rows
            |> Enum.filter(&(&1.device_id == device_id))
            |> Enum.map(& &1.identifier_value)
            |> Enum.reject(&(&1 in [nil, ""]))
            |> MapSet.new()

          {device_id, ids}
        end)

      nonempty = Enum.reject(sets, fn {_device_id, ids} -> MapSet.size(ids) == 0 end)

      if disjoint_nonempty_sets?(nonempty) do
        %{
          identifier_type: type,
          partition: partition,
          source_id: blank_to_nil(source_id),
          device_ids: Enum.sort(device_ids),
          source_ids:
            Map.new(sets, fn {device_id, ids} ->
              {device_id, ids |> MapSet.to_list() |> Enum.sort()}
            end)
        }
      end
    end)
  end

  def conflict_from_rows(_rows, _device_ids), do: nil

  @spec record_blocked(map(), String.t(), map()) :: :ok | {:error, term()}
  def record_blocked(details, reason, evidence \\ %{})

  def record_blocked(details, reason, evidence) when is_map(details) do
    now = DateTime.utc_now()
    [first_device | _] = details.device_ids

    source_values =
      details.source_ids |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

    DecisionLog.record(:source_block, "source_authority_conflict", details.device_ids,
      source: reason,
      evidence: %{
        "merge_reason" => reason,
        "identifier_type" => Atom.to_string(details.identifier_type),
        "source_id" => details.source_id,
        "partition" => details.partition,
        "source_ids" => details.source_ids,
        "evidence" => evidence
      }
    )

    # The Armis source-identity diagnostics (northbound withholding, drift reports) read this
    # table for `source_type = 'armis'`; the identity decision above is the reconciliation record.
    SourceIdentityDrift.record_conflicts([
      %{
        source_type: SourceIdentityDrift.source_type_for(details.identifier_type),
        source_id: details.source_id,
        source_identifier_type: Atom.to_string(details.identifier_type),
        source_identifier_value: Enum.join(source_values, ","),
        device_uid: first_device,
        conflict_category: "automatic_merge_source_authority_conflict",
        conflicting_identifiers: %{
          "device_ids" => details.device_ids,
          "source_ids" => details.source_ids,
          "partition" => details.partition
        },
        proposed_action: "block_automatic_merge",
        confidence: "high",
        first_detected_at: now,
        last_detected_at: now,
        metadata: %{"merge_reason" => reason, "evidence" => evidence}
      }
    ])
  end

  def record_blocked(_details, _reason, _evidence), do: :ok

  defp identifier_rows(device_ids, lock?) do
    query =
      from(identifier in DeviceIdentifier,
        where:
          identifier.device_id in ^device_ids and
            identifier.identifier_type in ^@source_identifier_types,
        select: %{
          device_id: identifier.device_id,
          identifier_type: identifier.identifier_type,
          identifier_value: identifier.identifier_value,
          partition: identifier.partition,
          metadata: identifier.metadata
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query)
  end

  defp maybe_lock_ownership(_device_ids, false), do: :ok

  # The lock key is shared with the `device_identifiers` ownership trigger
  # (`platform.lock_armis_identifier_ownership`), which takes it for a write of
  # any source-authoritative identifier type, so a concurrent writer of either
  # type serializes with this check.
  defp maybe_lock_ownership(device_ids, true) do
    if Repo.in_transaction?() do
      sql = """
      SELECT pg_advisory_xact_lock(
               hashtextextended('serviceradar:armis-identifier-owner:' || device_id, 0)
             )
      FROM (
        SELECT DISTINCT unnest($1::text[]) AS device_id
        ORDER BY device_id
      ) ordered_devices
      """

      case SQL.query(Repo, sql, [Enum.sort(Enum.uniq(device_ids))]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:source_authority_lock_failed, reason}}
      end
    else
      {:error, :source_authority_lock_requires_transaction}
    end
  end

  defp disjoint_nonempty_sets?(sets) when length(sets) < 2, do: false

  defp disjoint_nonempty_sets?(sets) do
    Enum.any?(sets, fn {left_device, left_ids} ->
      Enum.any?(sets, fn {right_device, right_ids} ->
        left_device < right_device and MapSet.disjoint?(left_ids, right_ids)
      end)
    end)
  end

  # Identifier types arrive as atoms from Ash and Ecto, and as strings from raw rows.
  defp identifier_type(type) when is_atom(type), do: type

  defp identifier_type(type) when is_binary(type),
    do: Enum.find(@source_identifier_types, &(Atom.to_string(&1) == type))

  defp source_id(row) do
    metadata = row.metadata || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id] || ""
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
