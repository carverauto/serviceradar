defmodule ServiceRadar.Inventory.Identity.IdentityProjections do
  @moduledoc """
  The values on a device row that repeat one of its identifiers, and their removal when they name
  another record's identity (OpenSpec `remediate-awx-proxmox-guest-merges`, requirement "An
  Unmerge Leaves Neither Record Describing The Other's Identity").

  Identifier rows are the identity; these values are projections of it:

    * the display MAC column (`ocsf_devices.mac`);
    * the entries of the metadata `mac_addresses` list;
    * the guest binding metadata Proxmox enrichment writes: `integration_id` and
      `integration_type`, and the `hypervisor_*` keys of a hypervisor binding;
    * the `awx` metadata, which names its AWX host (`claimed_awx_id/1`).

  A merge copies some of them onto the survivor, enrichment and sync write them onto whatever
  record held an identifier at the time, and nothing moves them back. `MergeEngine.unmerge_device/2`
  therefore removes from each record of the pair the projections naming the other record's
  identifiers (`drop/2`).
  """

  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Repo

  @integration_keys ~w(integration_id integration_type)
  @hypervisor_keys ~w(
    hypervisor_provider
    hypervisor_provider_ref
    hypervisor_host_provider_ref
    hypervisor_vmid
    hypervisor_guest_type
    hypervisor_status
  )

  @typedoc "Identifier values another record holds: normalized MACs and integration ids."
  @type foreign :: %{macs: MapSet.t(String.t()), integration_ids: MapSet.t(String.t())}

  @doc """
  The AWX v2 integration id an `awx` metadata map names (`awx:v2:<controller>:host:<id>`), or
  `nil` when it does not name both its controller and its host.
  """
  @spec claimed_awx_id(term()) :: String.t() | nil
  def claimed_awx_id(%{} = awx) do
    with controller when is_binary(controller) <- scalar(awx, "controller_id"),
         host when is_binary(host) <- scalar(awx, "host_id") do
      "awx:v2:" <> controller <> ":host:" <> host
    end
  end

  def claimed_awx_id(_awx), do: nil

  defp scalar(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  The `foreign` set of identifier rows (`%{type, value}` maps with string or atom keys, as a merge
  audit row or a read records them). Only MAC and integration id rows have projections.
  """
  @spec foreign([map()]) :: foreign()
  def foreign(identifiers) do
    Enum.reduce(List.wrap(identifiers), %{macs: MapSet.new(), integration_ids: MapSet.new()}, fn
      %{} = row, acc ->
        type = to_string(field(row, :type))
        value = field(row, :value)

        cond do
          not is_binary(value) ->
            acc

          type == "mac" ->
            %{acc | macs: Enum.into(Mac.normalize_mac_list(value), acc.macs)}

          type == "integration_id" ->
            %{acc | integration_ids: MapSet.put(acc.integration_ids, value)}

          true ->
            acc
        end

      _other, acc ->
        acc
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc """
  What removing the `foreign` projections changes on a row with this display `mac` and
  `metadata`: `%{mac: {:set, value} | :keep, delete: [key], put: map, dropped: map}`. `dropped`
  holds each removed value, and is empty when nothing changes.
  """
  @spec plan(String.t() | nil, map() | nil, foreign()) :: map()
  def plan(mac, metadata, foreign) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    {mac_change, mac_dropped} = mac_change(mac, foreign.macs)
    {list_put, list_delete, list_dropped} = mac_addresses_change(metadata, foreign.macs)
    binding_delete = binding_keys(metadata, foreign.integration_ids)

    awx_delete =
      if MapSet.member?(foreign.integration_ids, claimed_awx_id(metadata["awx"])),
        do: ["awx"],
        else: []

    delete = list_delete ++ binding_delete ++ awx_delete

    dropped =
      %{}
      |> put_present("mac", mac_dropped)
      |> put_present("mac_addresses", list_dropped)
      |> put_present("metadata", Map.take(metadata, binding_delete ++ awx_delete))

    %{mac: mac_change, delete: delete, put: list_put, dropped: dropped}
  end

  defp mac_change(mac, foreign_macs) when is_binary(mac) do
    tokens = Mac.normalize_mac_list(mac)
    kept = Enum.reject(tokens, &MapSet.member?(foreign_macs, &1))

    cond do
      kept == tokens -> {:keep, nil}
      kept == [] -> {{:set, nil}, mac}
      true -> {{:set, Enum.join(kept, ",")}, mac}
    end
  end

  defp mac_change(_mac, _foreign_macs), do: {:keep, nil}

  defp mac_addresses_change(%{"mac_addresses" => list}, foreign_macs) when is_list(list) do
    {dropped, kept} = Enum.split_with(list, &foreign_mac_entry?(&1, foreign_macs))

    cond do
      dropped == [] -> {%{}, [], nil}
      kept == [] -> {%{}, ["mac_addresses"], dropped}
      true -> {%{"mac_addresses" => kept}, [], dropped}
    end
  end

  defp mac_addresses_change(_metadata, _foreign_macs), do: {%{}, [], nil}

  defp foreign_mac_entry?(entry, foreign_macs) do
    tokens = Mac.normalize_mac_list(entry)
    tokens != [] and Enum.all?(tokens, &MapSet.member?(foreign_macs, &1))
  end

  # The integration keys go when the record's `integration_id` is foreign; the hypervisor keys go
  # when the binding they describe is foreign: its provider reference, or a hypervisor binding's
  # integration id.
  defp binding_keys(metadata, foreign_ids) do
    foreign_integration? = MapSet.member?(foreign_ids, metadata["integration_id"])

    foreign_binding? =
      MapSet.member?(foreign_ids, metadata["hypervisor_provider_ref"]) or
        (foreign_integration? and metadata["integration_type"] == "hypervisor")

    integration = if foreign_integration?, do: @integration_keys, else: []
    hypervisor = if foreign_binding?, do: @hypervisor_keys, else: []
    Enum.filter(integration ++ hypervisor, &Map.has_key?(metadata, &1))
  end

  defp put_present(map, _key, value) when value in [nil, [], %{}], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Removes from device `uid` the projections naming the `foreign` identifiers, and returns what
  it removed (`plan/3`'s `dropped`). The caller holds the device row's lock.
  """
  @spec drop(String.t(), foreign()) :: {:ok, map()} | {:error, term()}
  def drop(uid, foreign) do
    case Repo.query("SELECT mac, metadata FROM platform.ocsf_devices WHERE uid = $1", [uid]) do
      {:ok, %{rows: [[mac, metadata]]}} ->
        plan = plan(mac, metadata, foreign)

        if plan.dropped == %{} do
          {:ok, %{}}
        else
          write(uid, mac, plan)
        end

      {:ok, %{rows: []}} ->
        {:ok, %{}}

      {:error, _} = error ->
        error
    end
  end

  # Only the removed keys and the rewritten list are touched, so a concurrent writer's other
  # metadata keys survive.
  defp write(uid, mac, plan) do
    new_mac =
      case plan.mac do
        {:set, value} -> value
        :keep -> mac
      end

    case Repo.query(
           """
           UPDATE platform.ocsf_devices
           SET mac = $2,
               metadata = (COALESCE(metadata, '{}'::jsonb) - $3::text[]) || $4::jsonb,
               modified_time = timezone('UTC', now())
           WHERE uid = $1
           """,
           [uid, new_mac, plan.delete, plan.put]
         ) do
      {:ok, _result} -> {:ok, plan.dropped}
      {:error, _} = error -> error
    end
  end
end
