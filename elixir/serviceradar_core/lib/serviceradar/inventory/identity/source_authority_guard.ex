defmodule ServiceRadar.Inventory.Identity.SourceAuthorityGuard do
  @moduledoc """
  Fail-closed guard for automatic merges across source-authoritative IDs.

  A MAC, IP, hostname, or transitive duplicate edge cannot authorize combining
  two non-empty, disjoint Armis identity sets from the same source scope.

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

  @typed_identifier :armis_device_id

  @typedoc "Source-authoritative identifiers per device, as `{partition, value}` pairs."
  @type held :: %{String.t() => MapSet.t({String.t(), String.t()})}

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
        |> Ash.Query.filter(device_id in ^device_ids and identifier_type == ^@typed_identifier)
        |> Ash.Query.select([:device_id, :identifier_value, :partition])
        |> Page.stream!(query_opts)
        |> Enum.group_by(& &1.device_id, &{&1.partition, &1.identifier_value})
        |> Map.new(fn {device_id, pairs} -> {device_id, MapSet.new(pairs)} end)
    end
  end

  @doc """
  True when an update carrying `ids` must not resolve onto `device_id`: the
  update carries a source-authoritative identifier, the device holds at least
  one in the update's scope (its identifier partition, which carries the sync
  source), and none of them is the update's.

  A device holding no source-authoritative identifier is not a mismatch: a
  discovered record of the same device, found through its MAC, is what the
  source-authoritative identifier should attach to.
  """
  @spec source_mismatch?(Ids.strong_identifiers(), String.t(), held()) :: boolean()
  def source_mismatch?(ids, device_id, held) do
    case Ids.ids_get(ids, :armis_id) do
      value when is_binary(value) and value != "" ->
        scoped = scoped_source_ids(held, device_id, Ids.ids_get_partition(ids))
        scoped != [] and value not in scoped

      _ ->
        false
    end
  end

  @doc "The source-authoritative identifiers `device_id` holds in `partition`, sorted."
  @spec scoped_source_ids(held(), String.t(), String.t()) :: [String.t()]
  def scoped_source_ids(held, device_id, partition) do
    held
    |> Map.get(device_id, MapSet.new())
    |> Enum.flat_map(fn
      {^partition, value} -> [value]
      _other -> []
    end)
    |> Enum.sort()
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
    overrides = Enum.uniq_by(overrides, &{&1.device_uid, Ids.ids_get(&1.ids, :armis_id)})

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
        "armis_device_id" => Ids.ids_get(override.ids, :armis_id),
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
    |> Enum.group_by(fn row -> {row.partition, source_id(row)} end)
    |> Enum.find_value(fn {{partition, source_id}, scoped_rows} ->
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
        "source_id" => details.source_id,
        "partition" => details.partition,
        "source_ids" => details.source_ids,
        "evidence" => evidence
      }
    )

    # The Armis source-identity diagnostics (northbound withholding, drift reports) read this
    # table; the identity decision above is the reconciliation record.
    SourceIdentityDrift.record_conflicts([
      %{
        source_type: "armis",
        source_id: details.source_id,
        source_identifier_type: "armis_device_id",
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
            identifier.identifier_type == ^@typed_identifier,
        select: %{
          device_id: identifier.device_id,
          identifier_value: identifier.identifier_value,
          partition: identifier.partition,
          metadata: identifier.metadata
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query)
  end

  defp maybe_lock_ownership(_device_ids, false), do: :ok

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

  defp source_id(row) do
    metadata = row.metadata || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id] || ""
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
