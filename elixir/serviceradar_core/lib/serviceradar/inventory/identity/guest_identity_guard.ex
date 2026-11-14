defmodule ServiceRadar.Inventory.Identity.GuestIdentityGuard do
  @moduledoc """
  Refuses an automatic merge of two records that hold different virtualization guests
  (change `add-distinct-guest-identity-merge-guard`; requirement "Distinct Virtualization Guest
  Identities Never Merge Automatically").

  A guest identity is a live `integration_id` identifier that names one hypervisor guest
  (`guest_identity/1`). Two records whose guest identities differ, so that neither record's set
  contains the other's, are different machines, and no MAC, address, hostname or transitive
  edge decides otherwise. One record holding the other's guest identities, or holding none, is
  not proof of a different machine: a record of the same guest seen again, an AWX host, an
  agent's record and a discovered record merge as before.

  Only Proxmox mints guest identities today (`ServiceRadar.Inventory.IntegrationIdentity`):

    * v3, `proxmox:v3:<integration>:<controller>:<cluster>:<qemu|lxc>:<vmid>`, the
      authoritative identity. Any differing component is a different guest.
    * v2, `proxmox:v2:<cluster>:<vm|lxc>:<vmid>`, the legacy cluster-scoped identity.

  The two generations are compared only within themselves. A v2 value names no integration or
  controller, so it does not prove which v3 guest it is; the alias reconciler
  (`ServiceRadar.Inventory.VirtualizationIdentityAliases`) decides that, and quarantines a
  legacy value that more than one v3 guest claims. Node and cluster references are not guest
  identities.

  Only live identifiers count. An identifier retired to `device_identifier_archive` no longer
  names the record's guest, so it never blocks the merge that converges its record.

  A record never gains a second live v3 guest (change `prevent-multi-guest-device-records`,
  requirement "A Device Record Never Gains A Second Live Hypervisor Guest"). `added_guests/2` is
  the one rule for it, asked by resolution (`BatchResolver`), by identifier registration
  (`drop_added_guest_rows/2`, from `IdentifierRecords` and `Registrar`) and by the merge guard
  (`merge_conflict/3`): the subset rule above lets a record holding guests A and B merge into a
  record holding A, and that survivor would gain B.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IntegrationIdentity

  require Ash.Query
  require Logger

  @typedoc "A guest identity: its generation and its canonical value."
  @type guest_identity :: {:proxmox_v2 | :proxmox_v3, String.t()}

  @v2_guest_kinds ~w(vm lxc)
  @v3_guest_kinds ~w(qemu lxc)

  @doc """
  The guest identity an `integration_id` value names, or `:error` for any other value.
  """
  @spec guest_identity(term()) :: {:ok, guest_identity()} | :error
  def guest_identity(value) when is_binary(value) do
    with :error <- v3_guest(value) do
      v2_guest(value)
    end
  end

  def guest_identity(_value), do: :error

  defp v3_guest(value) do
    case IntegrationIdentity.parse_v3(value) do
      {:ok, %{object_kind: kind, provider_ref: ref}} when kind in @v3_guest_kinds ->
        {:ok, {:proxmox_v3, ref}}

      _ ->
        :error
    end
  end

  defp v2_guest(value) do
    case IntegrationIdentity.parse_v2(value) do
      {:ok, %{kind: kind}} when kind in @v2_guest_kinds -> {:ok, {:proxmox_v2, value}}
      _ -> :error
    end
  end

  @doc """
  The guest identities that set the two records apart, or `nil` when their guest identities do
  not prove them different machines.

  `held_a` and `held_b` are the guest identities each record holds. Within a generation, the
  records differ when both hold identities of it and neither set contains the other.
  """
  @spec conflict([guest_identity()], [guest_identity()]) :: map() | nil
  def conflict(held_a, held_b) when is_list(held_a) and is_list(held_b) do
    by_generation_a = by_generation(held_a)
    by_generation_b = by_generation(held_b)

    by_generation_a
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find_value(fn generation ->
      a = Map.fetch!(by_generation_a, generation)
      b = Map.get(by_generation_b, generation, MapSet.new())

      if distinct_sets?(a, b) do
        %{generation: generation, a: Enum.sort(a), b: Enum.sort(b)}
      end
    end)
  end

  defp by_generation(held) do
    held
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {generation, values} -> {generation, MapSet.new(values)} end)
  end

  defp distinct_sets?(a, b) do
    MapSet.size(a) > 0 and MapSet.size(b) > 0 and not MapSet.subset?(a, b) and
      not MapSet.subset?(b, a)
  end

  @doc """
  The guest identities that set `from_device_id` and `to_device_id` apart, as evidence for the
  blocked-merge record, or `nil` when the merge is not refused.
  """
  @spec merge_conflict(String.t(), String.t(), term()) :: map() | nil
  def merge_conflict(from_device_id, to_device_id, actor) do
    held = held_guest_identities([from_device_id, to_device_id], actor)
    from_held = Map.get(held, from_device_id, [])
    to_held = Map.get(held, to_device_id, [])

    case conflict(from_held, to_held) do
      nil ->
        survivor_gain_conflict(from_held, to_held)

      %{generation: generation, a: from_refs, b: to_refs} ->
        merge_evidence(generation, from_refs, to_refs)
    end
  end

  # The merged record's guests contain the survivor's, so `conflict/2` allows the merge, but the
  # survivor would gain a guest and hold more than one.
  defp survivor_gain_conflict(from_held, to_held) do
    from_refs = v3_values(from_held)
    to_refs = v3_values(to_held)

    case added_guests(to_refs, from_refs) do
      [] -> nil
      _gained -> merge_evidence(:proxmox_v3, Enum.sort(from_refs), Enum.sort(to_refs))
    end
  end

  defp merge_evidence(generation, from_refs, to_refs) do
    %{
      "generation" => Atom.to_string(generation),
      "from_guest_identities" => from_refs,
      "to_guest_identities" => to_refs
    }
  end

  defp v3_values(held), do: for({:proxmox_v3, ref} <- held, do: ref)

  @doc """
  The v3 guest references a record holding the identifier values `held` would gain from
  `incoming` while ending up with more than one, sorted. Empty when the operation gives the
  record no second guest: the same guest again, a first guest, or guests it already holds.

  Values that are not v3 guest references (node references, legacy v2 references, AWX ids,
  MACs) are ignored on both sides.
  """
  @spec added_guests([term()], [term()]) :: [String.t()]
  def added_guests(held, incoming) when is_list(held) and is_list(incoming) do
    held = v3_guest_refs(held)
    incoming = v3_guest_refs(incoming)
    gained = MapSet.difference(incoming, held)

    if MapSet.size(gained) > 0 and MapSet.size(MapSet.union(held, incoming)) > 1,
      do: Enum.sort(gained),
      else: []
  end

  defp v3_guest_refs(values) do
    MapSet.new(for value <- values, {:ok, {:proxmox_v3, ref}} <- [guest_identity(value)], do: ref)
  end

  @doc "Whether `value` is a v3 guest reference."
  @spec v3_guest_ref?(term()) :: boolean()
  def v3_guest_ref?(value), do: match?({:ok, {:proxmox_v3, _ref}}, guest_identity(value))

  @doc "The live v3 guest references each of `device_ids` holds, by device."
  @spec held_v3_refs([String.t()], term()) :: %{String.t() => MapSet.t(String.t())}
  def held_v3_refs([], _actor), do: %{}

  def held_v3_refs(device_ids, actor) do
    device_ids
    |> Enum.uniq()
    |> held_guest_identities(actor)
    |> Map.new(fn {device_id, held} -> {device_id, MapSet.new(v3_values(held))} end)
  end

  @doc """
  Identifier rows to register, without each v3 guest reference row that would give its record a
  second guest, counting the rows registered before it in `rows`. Rows are maps with
  `:device_id`, `:identifier_type` and `:identifier_value`.

  A writer that registers identifiers without resolution (hypervisor enrichment's MAC sync,
  `Registrar`) reaches this only through a resolution defect, so a dropped row is logged at error
  level and emitted as `[:serviceradar, :inventory, :guest_identity, :attach_refused]`. The other
  rows are kept.
  """
  @spec drop_added_guest_rows([map()], String.t()) :: [map()]
  def drop_added_guest_rows(rows, source) when is_list(rows) do
    case rows |> Enum.filter(&v3_guest_row?/1) |> Enum.map(& &1.device_id) do
      [] -> rows
      device_ids -> do_drop_added_guest_rows(rows, device_ids, source)
    end
  end

  defp do_drop_added_guest_rows(rows, device_ids, source) do
    held = held_v3_refs(device_ids, SystemActor.system(:guest_identity_guard))

    {kept, _held} =
      Enum.flat_map_reduce(rows, held, fn row, held ->
        current = Map.get(held, row.device_id, MapSet.new())

        cond do
          not v3_guest_row?(row) ->
            {[row], held}

          added_guests(MapSet.to_list(current), [row.identifier_value]) == [] ->
            {[row], Map.put(held, row.device_id, MapSet.put(current, row.identifier_value))}

          true ->
            report_refused_attach(row, current, source)
            {[], held}
        end
      end)

    kept
  end

  defp v3_guest_row?(%{identifier_type: type, identifier_value: value})
       when type in [:integration_id, "integration_id"],
       do: v3_guest_ref?(value)

  defp v3_guest_row?(_row), do: false

  defp report_refused_attach(row, held, source) do
    Logger.error(
      "GuestIdentityGuard: refused to register #{row.identifier_value} on #{row.device_id}, " <>
        "which holds #{inspect(Enum.sort(held))} (#{source}); resolution should have given " <>
        "the guest its own record"
    )

    :telemetry.execute(
      [:serviceradar, :inventory, :guest_identity, :attach_refused],
      %{count: 1},
      %{device_uid: row.device_id, guest_identity: row.identifier_value, source: source}
    )
  end

  @doc "The live guest identities each of `device_ids` holds, by device."
  @spec held_guest_identities([String.t()], term()) :: %{String.t() => [guest_identity()]}
  def held_guest_identities(device_ids, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.filter(device_id in ^device_ids and identifier_type == :integration_id)
    |> Ash.Query.select([:device_id, :identifier_value])
    |> Page.stream!(query_opts)
    |> Enum.flat_map(fn row ->
      case guest_identity(row.identifier_value) do
        {:ok, identity} -> [{row.device_id, identity}]
        :error -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
