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
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IntegrationIdentity

  require Ash.Query

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

    case conflict(Map.get(held, from_device_id, []), Map.get(held, to_device_id, [])) do
      nil ->
        nil

      %{generation: generation, a: from_refs, b: to_refs} ->
        %{
          "generation" => Atom.to_string(generation),
          "from_guest_identities" => from_refs,
          "to_guest_identities" => to_refs
        }
    end
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
