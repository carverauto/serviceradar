defmodule ServiceRadar.Inventory.Identity.SourceAuthorityGuard do
  @moduledoc """
  Fail-closed guard for automatic merges across source-authoritative IDs.

  A MAC, IP, hostname, or transitive duplicate edge cannot authorize combining
  two non-empty, disjoint identity sets of one source-authoritative identifier
  type (`source_identifier_types/0`: the Armis device id and the NetBox device
  id) from the same source scope. An `integration_id` is not
  source-authoritative.

  The same rule governs resolution: an update carrying a source-authoritative
  identifier never resolves onto a record, through a shared MAC or any other
  identifier, when that record holds a different source-authoritative
  identifier in the same scope. The source-authoritative identifier decides,
  the shared identifier is evidence only, and the override is recorded
  (`source_mismatch?/3`, `record_overrides/1`).

  A record's history of a type is the values it holds in `device_identifiers` together with
  the values it held: the rows moved to `device_identifier_archive` when an identifier
  retired (`ServiceRadar.Inventory.Identity.SourceRetirement`). A retired identifier keeps
  deciding. A record that holds or held a value of the type is never an ingest match for an
  update carrying a value it does not currently hold, and two records that each have a
  history of one type in one scope never merge automatically, even when the values are equal
  (change `add-source-id-succession`, design D2).

  A retired identifier its source reports again is not matched here at all:
  `ServiceRadar.Inventory.Identity.SourceReactivation` returns it to the record that held it,
  or re-issues it, before resolution (D6).
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

  @db_prefix "platform"
  @archive_table "device_identifier_archive"

  # Source-authoritative identifier types, with the key each is extracted under
  # (`Ids.extract_strong_identifiers/1`). Two different values of one type in one
  # scope are two different devices, whatever other evidence says. The scope is
  # the identifier partition, which is also the scope a value is unique in: Armis
  # partitions carry the sync source, and the NetBox device id carries its source
  # in the value.
  @source_identifiers [armis_device_id: :armis_id, netbox_device_id: :netbox_id]
  @source_identifier_types Keyword.keys(@source_identifiers)

  @typedoc """
  The source-authoritative identifier history per device, as
  `{identifier_type, partition, value, state}` tuples: `:live` for an identifier the device
  holds, `:archived` for one it held that retired.
  """
  @type held :: %{
          String.t() => MapSet.t({atom(), String.t(), String.t(), :live | :archived})
        }

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
        claims = MapSet.new(pairs, fn {type, value} -> {type, partition, value, :live} end)
        Map.update(held, device_id, claims, &MapSet.union(&1, claims))
    end
  end

  @doc """
  The source-authoritative identifier history of each of `device_ids`: the identifiers it
  holds and the retired identifiers it held.
  """
  @spec held_source_ids([String.t()], term()) :: held()
  def held_source_ids(device_ids, actor) do
    case device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      device_ids ->
        query_opts = if actor, do: [actor: actor], else: []

        live =
          DeviceIdentifier
          |> Ash.Query.filter(
            device_id in ^device_ids and identifier_type in ^@source_identifier_types
          )
          |> Ash.Query.select([:device_id, :identifier_type, :identifier_value, :partition])
          |> Page.stream!(query_opts)
          |> Enum.map(&held_entry(&1, :live))

        archived = device_ids |> archived_rows(false) |> Enum.map(&held_entry(&1, :archived))

        (live ++ archived)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {device_id, entries} -> {device_id, MapSet.new(entries)} end)
    end
  end

  defp held_entry(row, state) do
    {row.device_id,
     {identifier_type(row.identifier_type), row.partition, row.identifier_value, state}}
  end

  @doc """
  True when an update carrying `ids` must not resolve onto `device_id`: for some
  source-authoritative identifier type the update carries, the device holds or held at least
  one value of that type in the update's scope (its identifier partition), and it does not
  currently hold the update's.

  A retired value counts: a record whose only identifier of the type retired is not a match
  for an update carrying a different one. Nor is it a match for an update carrying the
  retired value itself: `SourceReactivation` decides whether that value returns to the
  record, and once it has, the record holds it again.

  A device with no history of that type is not a mismatch: a discovered record of the same
  device, found through its MAC, or a record of the same device from a different source, is
  what the source-authoritative identifier should attach to.
  """
  @spec source_mismatch?(Ids.strong_identifiers(), String.t(), held()) :: boolean()
  def source_mismatch?(ids, device_id, held) do
    partition = Ids.ids_get_partition(ids)

    Enum.any?(update_source_ids(ids), fn {type, value} ->
      history = scoped_history(held, device_id, type, partition)
      history != [] and {value, :live} not in history
    end)
  end

  @doc """
  The source-authoritative identifiers `device_id` holds or held in the update's scope, of the
  types the update carries, sorted.
  """
  @spec scoped_source_ids(held(), String.t(), Ids.strong_identifiers()) :: [String.t()]
  def scoped_source_ids(held, device_id, ids) do
    partition = Ids.ids_get_partition(ids)

    ids
    |> update_source_ids()
    |> Enum.flat_map(fn {type, _value} ->
      held |> scoped_history(device_id, type, partition) |> Enum.map(&elem(&1, 0))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scoped_history(held, device_id, type, partition) do
    held
    |> Map.get(device_id, MapSet.new())
    |> Enum.flat_map(fn
      {^type, ^partition, value, state} -> [{value, state}]
      _other -> []
    end)
  end

  @doc """
  The identifier type and partition suffix an exact collection of a source instance accounts
  for, or `:error` for a source that has no exact collections.

  An exact Armis collection (`ServiceRadar.Inventory.ArmisSourceSnapshot`) is the complete set
  of Armis device ids one integration source reported in one sync run, and that source's ids
  live in identifier partitions ending in `:armis:<source id>`
  (`ServiceRadar.Inventory.Identity.Ids`). No other source-authoritative type has exact
  collections, so none of its identifiers can be proven absent.
  """
  @spec collection_scope(String.t(), String.t()) ::
          {:ok, %{identifier_type: atom(), partition_suffix: String.t()}} | :error
  def collection_scope("armis", source_instance)
      when is_binary(source_instance) and source_instance != "" do
    {:ok, %{identifier_type: :armis_device_id, partition_suffix: ":armis:" <> source_instance}}
  end

  def collection_scope(_source, _source_instance), do: :error

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

  # Two or more of `device_ids` with a history of one source-authoritative type in one scope
  # conflict: their current values (`source_ids`) and their retired ones (`retired_source_ids`,
  # rows marked `archived: true`) are different devices' identities, or the same identity held
  # twice, and either way no automatic merge may decide between them.
  @doc false
  def conflict_from_rows(rows, device_ids) when is_list(rows) and is_list(device_ids) do
    rows
    |> Enum.map(&Map.put(&1, :identifier_type, identifier_type(&1.identifier_type)))
    |> Enum.filter(
      &(&1.identifier_type in @source_identifier_types and &1.device_id in device_ids and
          &1.identifier_value not in [nil, ""])
    )
    |> Enum.group_by(&{&1.identifier_type, &1.partition, source_id(&1)})
    |> Enum.sort()
    |> Enum.find_value(fn {{type, partition, source_id}, scoped_rows} ->
      holders = scoped_rows |> Enum.map(& &1.device_id) |> Enum.uniq()

      if length(holders) >= 2 do
        %{
          identifier_type: type,
          partition: partition,
          source_id: blank_to_nil(source_id),
          device_ids: Enum.sort(device_ids),
          source_ids: scoped_values(scoped_rows, device_ids, false),
          retired_source_ids: scoped_values(scoped_rows, device_ids, true)
        }
      end
    end)
  end

  def conflict_from_rows(_rows, _device_ids), do: nil

  defp scoped_values(rows, device_ids, archived?) do
    Map.new(device_ids, fn device_id ->
      values =
        for row <- rows,
            row.device_id == device_id,
            Map.get(row, :archived, false) == archived?,
            uniq: true,
            do: row.identifier_value

      {device_id, Enum.sort(values)}
    end)
  end

  @spec record_blocked(map(), String.t(), map()) :: :ok | {:error, term()}
  def record_blocked(details, reason, evidence \\ %{})

  def record_blocked(details, reason, evidence) when is_map(details) do
    now = DateTime.utc_now()
    [first_device | _] = details.device_ids
    retired = Map.get(details, :retired_source_ids, %{})

    source_values =
      [details.source_ids, retired]
      |> Enum.flat_map(&Map.values/1)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    DecisionLog.record(:source_block, "source_authority_conflict", details.device_ids,
      source: reason,
      evidence: %{
        "merge_reason" => reason,
        "identifier_type" => Atom.to_string(details.identifier_type),
        "source_id" => details.source_id,
        "partition" => details.partition,
        "source_ids" => details.source_ids,
        "retired_source_ids" => retired,
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
          "retired_source_ids" => retired,
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

  # The live rows and the archived rows are read by separate statements: `FOR UPDATE` cannot
  # lock the rows of a `UNION`.
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
    Repo.all(query) ++ archived_rows(device_ids, lock?)
  end

  # The archive has no Ash resource; its rows keep the type as text.
  defp archived_rows(device_ids, lock?) do
    types = Enum.map(@source_identifier_types, &Atom.to_string/1)

    query =
      from(archived in @archive_table,
        where: archived.device_id in ^device_ids and archived.identifier_type in ^types,
        select: %{
          device_id: archived.device_id,
          identifier_type: archived.identifier_type,
          identifier_value: archived.identifier_value,
          partition: archived.partition,
          metadata: archived.metadata
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query

    query
    |> Repo.all(prefix: @db_prefix)
    |> Enum.map(
      &Map.merge(&1, %{identifier_type: identifier_type(&1.identifier_type), archived: true})
    )
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
