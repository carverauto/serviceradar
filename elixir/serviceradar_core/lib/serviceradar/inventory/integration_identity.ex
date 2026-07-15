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

  The v3 format is the authoritative virtualization identity. It adds the
  immutable ServiceRadar integration and controller UUIDs to the native
  Proxmox cluster scope, so two controllers with identical cluster names,
  node names, and VMIDs cannot collide:

    * provider instance:
      `proxmox:v3:<integration-uuid>:<controller-uuid>:<cluster>`
    * cluster:
      `<provider-instance>:cluster:<cluster>`
    * node: `<provider-instance>:node:<node-name>`
    * guest: `<provider-instance>:qemu:<vmid>` or
      `<provider-instance>:lxc:<vmid>`

  Native string components are percent-encoded with only URI-unreserved
  characters left literal. Structured fields remain authoritative; rendered
  refs are a canonical projection for joins and external contracts.
  """

  alias ServiceRadar.Inventory.IdentityReconciler

  @proxmox_v2_prefix "proxmox:v2:"
  @proxmox_v3_prefix "proxmox:v3:"
  @proxmox_v3_kinds ~w(cluster node qemu lxc)

  @type record_fields :: %{
          optional(atom() | String.t()) => term()
        }

  ## Minting

  @doc """
  Build the canonical structured v3 fields for a Proxmox inventory object.

  UUIDs are normalized through `Ecto.UUID`; native components are trimmed but
  otherwise retain their source value before canonical percent encoding.
  """
  @spec proxmox_v3_fields(term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()}
  def proxmox_v3_fields(
        integration_id,
        controller_id,
        native_cluster_id,
        object_kind,
        native_object_id
      ) do
    with {:ok, integration_id} <- canonical_uuid(integration_id),
         {:ok, controller_id} <- canonical_uuid(controller_id),
         {:ok, native_cluster_id} <- native_component(native_cluster_id),
         {:ok, object_kind} <- proxmox_v3_kind(object_kind),
         {:ok, native_object_id} <- native_object_component(object_kind, native_object_id) do
      provider_instance_ref =
        Enum.join(
          [
            "proxmox",
            "v3",
            integration_id,
            controller_id,
            encode_native_component(native_cluster_id)
          ],
          ":"
        )

      provider_ref =
        Enum.join(
          [
            provider_instance_ref,
            object_kind,
            encode_native_component(native_object_id)
          ],
          ":"
        )

      {:ok,
       %{
         identity_version: 3,
         identity_state: :authoritative,
         integration_id: integration_id,
         controller_id: controller_id,
         native_cluster_id: native_cluster_id,
         object_kind: object_kind,
         native_object_id: native_object_id,
         provider_instance_ref: provider_instance_ref,
         provider_ref: provider_ref
       }}
    end
  end

  @doc "Return a source-scoped child reference for non-object inventory rows."
  @spec proxmox_v3_child_ref(String.t(), String.t() | atom(), [term()]) ::
          {:ok, String.t()} | {:error, atom()}
  def proxmox_v3_child_ref(provider_instance_ref, kind, components)
      when is_binary(provider_instance_ref) and is_list(components) do
    with true <- String.starts_with?(provider_instance_ref, @proxmox_v3_prefix),
         {:ok, kind} <- native_component(to_string(kind)),
         {:ok, encoded_components} <- encode_native_components(components) do
      {:ok,
       Enum.join([provider_instance_ref, encode_native_component(kind) | encoded_components], ":")}
    else
      false -> {:error, :invalid_provider_instance_ref}
      {:error, _reason} = error -> error
    end
  end

  def proxmox_v3_child_ref(_provider_instance_ref, _kind, _components),
    do: {:error, :invalid_provider_instance_ref}

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

  @doc "Check whether a value is a canonical v3 Proxmox reference."
  @spec v3?(term()) :: boolean()
  def v3?(value) when is_binary(value) do
    case parse_v3(value) do
      {:ok, _parts} -> true
      :error -> false
    end
  end

  def v3?(_value), do: false

  @doc "Parse and canonicalize a v3 Proxmox object reference."
  @spec parse_v3(term()) :: {:ok, map()} | :error
  def parse_v3(@proxmox_v3_prefix <> rest = provider_ref) do
    with [integration_id, controller_id, encoded_cluster, kind, encoded_object] <-
           String.split(rest, ":"),
         {:ok, integration_id} <- canonical_uuid(integration_id),
         {:ok, controller_id} <- canonical_uuid(controller_id),
         {:ok, native_cluster_id} <- decode_native_component(encoded_cluster),
         {:ok, kind} <- proxmox_v3_kind(kind),
         {:ok, native_object_id} <- decode_native_component(encoded_object),
         {:ok, expected} <-
           proxmox_v3_fields(
             integration_id,
             controller_id,
             native_cluster_id,
             kind,
             native_object_id
           ),
         true <- expected.provider_ref == provider_ref do
      {:ok, expected}
    else
      _ -> :error
    end
  end

  def parse_v3(_value), do: :error

  @doc "Validate that structured v3 fields exactly render the supplied ref."
  @spec validate_v3_record(map()) :: :ok | {:error, atom()}
  def validate_v3_record(record) when is_map(record) do
    fields =
      Map.new(
        ~w(identity_version identity_state integration_id controller_id native_cluster_id object_kind native_object_id provider_instance_ref provider_ref)a,
        &{&1, field_value(record, [&1])}
      )

    v3_present? =
      fields.identity_version == 3 or
        fields.identity_state in [:authoritative, "authoritative"] or
        Enum.any?(
          ~w(integration_id controller_id native_cluster_id object_kind native_object_id provider_instance_ref)a,
          &present_value?(Map.get(fields, &1))
        ) or
        (is_binary(fields.provider_ref) and
           String.starts_with?(fields.provider_ref, @proxmox_v3_prefix))

    if v3_present? do
      with true <- fields.identity_version == 3,
           true <- fields.identity_state in [:authoritative, "authoritative"],
           {:ok, expected} <-
             proxmox_v3_fields(
               fields.integration_id,
               fields.controller_id,
               fields.native_cluster_id,
               fields.object_kind,
               fields.native_object_id
             ),
           true <- expected.provider_instance_ref == fields.provider_instance_ref,
           true <- expected.provider_ref == fields.provider_ref do
        :ok
      else
        _ -> {:error, :invalid_proxmox_v3_identity}
      end
    else
      :ok
    end
  end

  def validate_v3_record(_record), do: {:error, :invalid_proxmox_v3_identity}

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
      case parse_v3(v2_integration_id) do
        {:ok, %{object_kind: "node", native_object_id: node} = parsed} ->
          v3_node_legacy_candidates(parsed, node, record_fields)

        {:ok, %{object_kind: kind, native_object_id: ref} = parsed}
        when kind in ["qemu", "lxc"] ->
          v3_guest_legacy_candidates(parsed, kind, ref, record_fields)

        {:ok, %{object_kind: "cluster", native_cluster_id: cluster}} ->
          ["proxmox:cluster:#{legacy_cluster_name(cluster, record_fields)}"]

        :error ->
          v2_legacy_candidates(v2_integration_id, record_fields)
      end

    case_result
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == v2_integration_id))
  end

  def legacy_candidates(_v2_integration_id, _record_fields), do: []

  defp v2_legacy_candidates(v2_integration_id, record_fields) do
    case parse_v2(v2_integration_id) do
      {:ok, %{kind: "node", ref: node}} ->
        node_legacy_candidates(node, record_fields)

      {:ok, %{kind: kind, ref: ref}} ->
        guest_legacy_candidates(kind, ref, record_fields)

      :error ->
        []
    end
  end

  defp v3_node_legacy_candidates(parsed, node, fields) do
    cluster = legacy_cluster_name(parsed.native_cluster_id, fields)
    v2 = proxmox_node_id(cluster, node)

    [v2 | v2_legacy_candidates(v2, Map.put(fields, :node, node))]
  end

  defp v3_guest_legacy_candidates(parsed, kind, ref, fields) do
    cluster = legacy_cluster_name(parsed.native_cluster_id, fields)
    raw_kind = if kind == "qemu", do: "qemu", else: "lxc"
    v2 = proxmox_guest_id(cluster, raw_kind, ref)

    fields =
      fields
      |> Map.put_new(:guest_type, raw_kind)
      |> Map.put_new(:vmid, ref)

    [v2 | v2_legacy_candidates(v2, fields)]
  end

  defp legacy_cluster_name(native_cluster_id, fields) do
    field_string(fields, [:cluster_name, :legacy_cluster, :cluster]) ||
      native_cluster_id
      |> String.replace_prefix("cluster/", "")
      |> String.replace_prefix("standalone/", "")
  end

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

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp proxmox_v3_kind(kind) when is_atom(kind), do: proxmox_v3_kind(Atom.to_string(kind))

  defp proxmox_v3_kind(kind) when is_binary(kind) do
    case String.downcase(String.trim(kind)) do
      "vm" -> {:ok, "qemu"}
      "container" -> {:ok, "lxc"}
      normalized when normalized in @proxmox_v3_kinds -> {:ok, normalized}
      _ -> {:error, :invalid_object_kind}
    end
  end

  defp proxmox_v3_kind(_kind), do: {:error, :invalid_object_kind}

  defp native_object_component(kind, value) when kind in ["qemu", "lxc"] do
    case normalize_vmid(value) do
      vmid when is_integer(vmid) -> {:ok, Integer.to_string(vmid)}
      _ -> {:error, :invalid_native_object_id}
    end
  end

  defp native_object_component(_kind, value), do: native_component(value)

  defp native_component(value) when is_integer(value),
    do: native_component(Integer.to_string(value))

  defp native_component(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_native_component}
      trimmed -> {:ok, trimmed}
    end
  end

  defp native_component(_value), do: {:error, :invalid_native_component}

  defp encode_native_components(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, acc} ->
      case native_component(component) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [encode_native_component(normalized)]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp encode_native_component(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp decode_native_component(value) when is_binary(value) do
    decoded = URI.decode(value)

    with {:ok, normalized} <- native_component(decoded),
         true <- encode_native_component(normalized) == value do
      {:ok, normalized}
    else
      _ -> {:error, :noncanonical_native_component}
    end
  rescue
    _ -> {:error, :invalid_native_component}
  end

  defp decode_native_component(_value), do: {:error, :invalid_native_component}

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

  defp present_value?(nil), do: false
  defp present_value?(""), do: false
  defp present_value?(_value), do: true

  defp ids_get(ids, key) do
    Map.get(ids, key) || Map.get(ids, Atom.to_string(key))
  end
end
