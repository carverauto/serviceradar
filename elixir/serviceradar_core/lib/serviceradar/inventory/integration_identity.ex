defmodule ServiceRadar.Inventory.IntegrationIdentity do
  @moduledoc """
  Stable, versioned `integration_id` formats plus legacy-format bridging.

  Proxmox integration identifiers churned through three incompatible
  generations, each of which duplicated every guest:

    * **name-keyed** (gen 1): `proxmox:vm:<name>` / `proxmox:container:<name>`
      / `proxmox:hypervisor:<node>`, with `proxmox:vm:qemu/<vmid>` when the
      guest had no name
    * **MAC-keyed** (gen 2): `proxmox:vm:<MAC>` / `proxmox:container:<MAC>`
      (colon-separated uppercase MAC)
    * **current-gen** (gen 3, code paths still in tree): provider refs
      `proxmox:node:<node>` / `proxmox:guest:<node>:<type>:<vmid>` and device
      uid placeholders `proxmox:pve:<node>` / `proxmox:<kind>:<vmid>` /
      `proxmox:<kind>:<node>:<vmid>`

  The v2 format is versioned, cluster-scoped, and keyed on values that are
  stable in Proxmox across renames and NIC changes:

    * nodes:  `proxmox:v2:<cluster>:node:<node-name>`
    * guests: `proxmox:v2:<cluster>:<kind>:<vmid>` with kind in `vm` | `lxc`

  `<cluster>` is the Proxmox cluster name; standalone (non-clustered) nodes
  use the node name as the cluster scope. Segments are normalized (trimmed,
  downcased, `:`/whitespace replaced with `-`) so case or formatting churn in
  the source cannot rotate the identifier.

  `legacy_candidates/2` produces every legacy-format value that could
  identify the same object so resolution can consult them at lookup time,
  exactly like `IdentityReconciler.mac_lookup_values/1` does for the legacy
  MAC blob. Legacy values are **lookup-only bridges**: they must never be
  registered as new identifiers.
  """

  alias ServiceRadar.Inventory.IdentityReconciler

  @proxmox_v2_prefix "proxmox:v2:"

  @type record_fields :: %{
          optional(atom() | String.t()) => term()
        }

  ## Minting

  @doc """
  Mint the v2 integration id for a Proxmox node (hypervisor host).

  Returns `nil` when either segment is missing so callers can fall back to
  provider-ref behaviour instead of minting an unstable id.
  """
  @spec proxmox_node_id(String.t() | nil, String.t() | nil) :: String.t() | nil
  def proxmox_node_id(cluster, node) do
    with cluster when is_binary(cluster) <- segment(cluster),
         node when is_binary(node) <- segment(node) do
      @proxmox_v2_prefix <> cluster <> ":node:" <> node
    else
      _ -> nil
    end
  end

  @doc """
  Mint the v2 integration id for a Proxmox guest.

  `guest_type` accepts the raw Proxmox type (`"qemu"`/`"lxc"`) or an already
  normalized kind (`"vm"`/`"container"`/`"lxc"`). VMIDs are stable across
  renames and NIC changes, which is why they key the identifier.
  """
  @spec proxmox_guest_id(String.t() | nil, String.t() | nil, term()) :: String.t() | nil
  def proxmox_guest_id(cluster, guest_type, vmid) do
    with cluster when is_binary(cluster) <- segment(cluster),
         kind when is_binary(kind) <- proxmox_guest_kind(guest_type),
         vmid when is_integer(vmid) <- normalize_vmid(vmid) do
      @proxmox_v2_prefix <> cluster <> ":" <> kind <> ":" <> Integer.to_string(vmid)
    else
      _ -> nil
    end
  end

  @doc """
  Normalize a Proxmox guest type to the v2 kind segment (`vm` | `lxc`).
  """
  @spec proxmox_guest_kind(String.t() | nil) :: String.t() | nil
  def proxmox_guest_kind(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "qemu" -> "vm"
      "vm" -> "vm"
      "lxc" -> "lxc"
      "container" -> "lxc"
      "" -> nil
      other -> segment(other)
    end
  end

  def proxmox_guest_kind(_type), do: nil

  @doc """
  Check whether a value is a v2-format integration id.
  """
  @spec v2?(term()) :: boolean()
  def v2?(value) when is_binary(value), do: String.starts_with?(value, @proxmox_v2_prefix)
  def v2?(_value), do: false

  @doc """
  Parse a v2 integration id into its components.

  Returns `{:ok, %{provider: "proxmox", cluster: cluster, kind: kind, ref: ref}}`
  where `kind` is `"node"`, `"vm"`, or `"lxc"` and `ref` is the node name or
  the vmid (as a string), or `:error` for anything else.
  """
  @spec parse_v2(term()) :: {:ok, map()} | :error
  def parse_v2(@proxmox_v2_prefix <> rest) do
    case String.split(rest, ":") do
      [cluster, kind, ref] when cluster != "" and kind != "" and ref != "" ->
        {:ok, %{provider: "proxmox", cluster: cluster, kind: kind, ref: ref}}

      _ ->
        :error
    end
  end

  def parse_v2(_value), do: :error

  ## Legacy bridging

  @doc """
  All legacy-format integration_id values that could identify the same object
  as `v2_integration_id`.

  `record_fields` supplies source attributes the legacy generations keyed on
  (atom or string keys are accepted):

    * `:name` — guest/node name (gen-1 name-keyed ids)
    * `:node` — Proxmox node hosting the guest (current-gen node-scoped ids)
    * `:vmid` — guest vmid (defaults to the vmid parsed from the v2 id)
    * `:guest_type` / `:type` — raw Proxmox type (`"qemu"`/`"lxc"`)
    * `:guest_id` — raw Proxmox resource id (e.g. `"qemu/132"`)
    * `:macs` / `:mac` — guest NIC MAC(s), any common format (gen-2 MAC-keyed ids)

  Candidates are ordered strongest-first (vmid-scoped current-gen forms, then
  MAC-keyed, then name-keyed last) and never include the v2 id itself. They
  are lookup-only: never register them as new identifiers.
  """
  @spec legacy_candidates(String.t() | nil, record_fields()) :: [String.t()]
  def legacy_candidates(v2_integration_id, record_fields \\ %{})

  def legacy_candidates(v2_integration_id, record_fields)
      when is_binary(v2_integration_id) and is_map(record_fields) do
    case_result =
      case parse_v2(v2_integration_id) do
        {:ok, %{kind: "node", ref: node}} ->
          node_legacy_candidates(node, record_fields)

        {:ok, %{kind: kind, ref: ref}} ->
          guest_legacy_candidates(kind, ref, record_fields)

        :error ->
          []
      end

    case_result
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == v2_integration_id))
  end

  def legacy_candidates(_v2_integration_id, _record_fields), do: []

  @doc """
  All integration_id values to use for identity lookups, in priority order.

  Mirrors `IdentityReconciler.mac_lookup_values/1`: the canonical (v2) value
  first, legacy-format values last as lookup-only bridges to identifier rows
  written by earlier generations. Legacy values must never be registered as
  new identifiers.

  Accepts an ids map carrying `:integration_id` and optionally
  `:legacy_integration_ids` (atom or string keys).
  """
  @spec lookup_values(map()) :: [String.t()]
  def lookup_values(ids) when is_map(ids) do
    primary =
      ids
      |> ids_get(:integration_id)
      |> List.wrap()
      |> Enum.filter(&present?/1)

    legacy =
      ids
      |> ids_get(:legacy_integration_ids)
      |> List.wrap()
      |> Enum.filter(&present?/1)

    Enum.uniq(primary ++ legacy)
  end

  def lookup_values(_ids), do: []

  ## Internal — node candidates

  defp node_legacy_candidates(node, fields) do
    [node, field_string(fields, [:name, :node, :hostname])]
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      [
        # current-gen provider ref / placeholder uid forms
        "proxmox:node:#{name}",
        "proxmox:pve:#{name}",
        # gen-1 host form (live: proxmox:hypervisor:pve01)
        "proxmox:hypervisor:#{name}"
      ]
    end)
  end

  ## Internal — guest candidates

  defp guest_legacy_candidates(kind, ref, fields) do
    vmid = normalize_vmid(field_value(fields, [:vmid])) || normalize_vmid(ref)
    raw_type = raw_guest_type(fields, kind)
    name_prefix = legacy_name_prefix(kind)
    node = field_string(fields, [:node])
    name = field_string(fields, [:name])
    guest_id = field_string(fields, [:guest_id]) || default_guest_id(raw_type, vmid)
    macs = legacy_mac_values(fields)

    vmid_forms(kind, raw_type, name_prefix, node, vmid) ++
      id_as_name_forms(name_prefix, guest_id) ++
      mac_forms(name_prefix, macs) ++
      name_forms(name_prefix, name)
  end

  # Current-gen forms keyed on the stable vmid: provider refs written as
  # integration_id by the hypervisor placeholder path, and device-uid shaped
  # ids minted by the plugin/ingestor.
  defp vmid_forms(_kind, _raw_type, _name_prefix, _node, nil), do: []

  defp vmid_forms(kind, raw_type, name_prefix, node, vmid) do
    node_scoped =
      if present?(node) do
        for_result =
          for type <- Enum.uniq([raw_type, kind, name_prefix]) do
            ["proxmox:guest:#{node}:#{type}:#{vmid}", "proxmox:#{type}:#{node}:#{vmid}"]
          end

        List.flatten(for_result)
      else
        []
      end

    plain =
      for type <- Enum.uniq([raw_type, kind, name_prefix]) do
        "proxmox:#{type}:#{vmid}"
      end

    node_scoped ++ plain
  end

  # Gen-1 fallback where the raw resource id was used as the name
  # (live: proxmox:vm:qemu/132).
  defp id_as_name_forms(name_prefix, guest_id) do
    if present?(guest_id) do
      ["proxmox:#{name_prefix}:#{guest_id}"]
    else
      []
    end
  end

  # Gen-2 MAC-keyed ids (live: proxmox:vm:BC:24:11:BD:DA:44). MACs were
  # stored colon-separated uppercase.
  defp mac_forms(name_prefix, macs) do
    Enum.map(macs, &"proxmox:#{name_prefix}:#{&1}")
  end

  # Gen-1 name-keyed ids (live: proxmox:vm:dusk01, proxmox:container:traefik).
  # Weakest evidence (names are not unique), so they come last.
  defp name_forms(name_prefix, name) do
    if present?(name) do
      ["proxmox:#{name_prefix}:#{name}"]
    else
      []
    end
  end

  defp legacy_name_prefix("lxc"), do: "container"
  defp legacy_name_prefix("vm"), do: "vm"
  defp legacy_name_prefix(kind), do: kind

  defp raw_guest_type(fields, kind) do
    case field_string(fields, [:guest_type, :type]) do
      value when is_binary(value) ->
        case String.downcase(value) do
          "qemu" -> "qemu"
          "vm" -> "qemu"
          "lxc" -> "lxc"
          "container" -> "lxc"
          _other -> default_raw_type(kind)
        end

      _ ->
        default_raw_type(kind)
    end
  end

  defp default_raw_type("vm"), do: "qemu"
  defp default_raw_type("lxc"), do: "lxc"
  defp default_raw_type(kind), do: kind

  defp default_guest_id(raw_type, vmid) when is_integer(vmid), do: "#{raw_type}/#{vmid}"
  defp default_guest_id(_raw_type, _vmid), do: nil

  defp legacy_mac_values(fields) do
    raw_macs =
      List.wrap(field_value(fields, [:macs])) ++ List.wrap(field_value(fields, [:mac]))

    raw_macs
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&IdentityReconciler.normalize_mac_list/1)
    |> Enum.uniq()
    |> Enum.map(&colonize_mac/1)
    |> Enum.filter(&present?/1)
  end

  defp colonize_mac(
         <<a::binary-size(2), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(2), f::binary-size(2)>>
       ) do
    Enum.join([a, b, c, d, e, f], ":")
  end

  defp colonize_mac(_value), do: nil

  ## Internal — helpers

  defp normalize_vmid(vmid) when is_integer(vmid) and vmid >= 0, do: vmid

  defp normalize_vmid(vmid) when is_binary(vmid) do
    case Integer.parse(String.trim(vmid)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_vmid(_vmid), do: nil

  defp segment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[:\s]+/, "-")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp segment(_value), do: nil

  defp field_value(fields, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(fields, key) || Map.get(fields, Atom.to_string(key)) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp field_string(fields, keys) do
    case field_value(fields, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp ids_get(ids, key) do
    Map.get(ids, key) || Map.get(ids, Atom.to_string(key))
  end
end
