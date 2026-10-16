defmodule ServiceRadarWebNG.Topology.BitmapSource do
  @moduledoc """
  Bounded current inventory projection for the device bitmap index.

  Membership follows active operator inventory, so source-retired records are
  excluded even while their stable identities and historical geometry remain.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceFleetOrdinal
  alias ServiceRadar.Inventory.FleetIdentity

  require Ash.Query

  @actor SystemActor.system(:topology_bitmap_source)
  @base_facets ~w(vendor region vlan device_class os_name os_version availability)
  @page_size 500

  def supported_facets(:device) do
    with {:ok, keys} <- tag_keys(), do: {:ok, @base_facets ++ Enum.map(keys, &("tag:" <> &1))}
  end

  def supported_facets(_kind), do: {:error, :unsupported_entity}

  @doc "Bounded filter-builder metadata; contains configured fields, never fleet values."
  def query_descriptor do
    with {:ok, facets} <- supported_facets(:device), {:ok, keys} <- tag_keys() do
      labels = %{
        "vendor" => "Vendor",
        "region" => "Region",
        "vlan" => "Inventory VLAN",
        "device_class" => "Device class",
        "os_name" => "Operating system",
        "os_version" => "OS version",
        "availability" => "Availability"
      }

      {:ok,
       %{
         entity_kind: "device",
         facets: Enum.map(facets, &%{key: &1, label: Map.get(labels, &1, &1), operators: ["eq"]}),
         tag_keys: keys,
         operators: %{tag_key_prefix: false, ip_cidr: false}
       }}
    end
  end

  def initialize do
    with {:ok, facets} <- supported_facets(:device),
         epoch when is_binary(epoch) <- FleetIdentity.epoch(),
         {:ok, epoch} <- Ecto.UUID.dump(epoch) do
      {:ok, %{dictionary_epoch: epoch, supported_facets: facets}}
    else
      {:error, _} = error -> error
      _ -> {:error, :dictionary_unavailable}
    end
  end

  def backfill(cursor), do: FleetIdentity.backfill_devices(cursor, limit: @page_size)

  @doc "Stable canonical identities for a bounded Atlas ordinal projection, including tombstones."
  def identity_page(after_ordinal) do
    with {:ok, rows} <- dictionary_page(after_ordinal) do
      next_cursor = if length(rows) == @page_size, do: List.last(rows).ordinal
      {:ok, %{entries: Enum.map(rows, &{&1.uid, &1.ordinal}), next_cursor: next_cursor}}
    end
  end

  def resolve_ids(ids) when is_list(ids) and length(ids) <= @page_size do
    with {:ok, rows} <-
           dictionary()
           |> Ash.Query.filter(uid in ^ids)
           |> Ash.read() do
      {:ok, Enum.map(rows, & &1.ordinal)}
    end
  end

  def resolve_ids(_ids), do: {:error, :invalid_batch}

  def page(after_ordinal, facets) when is_integer(after_ordinal) and after_ordinal >= 0 do
    with {:ok, dictionary} <- dictionary_page(after_ordinal),
         {:ok, rows} <- project(dictionary, facets) do
      cursor =
        case List.last(dictionary) do
          nil -> after_ordinal
          row -> row.ordinal
        end

      {:ok, %{rows: rows, cursor: cursor, done?: length(dictionary) < @page_size}}
    end
  end

  def fetch(ordinals, facets) when is_list(ordinals) and length(ordinals) <= @page_size do
    with {:ok, dictionary} <- dictionary() |> Ash.Query.filter(ordinal in ^ordinals) |> Ash.read(),
         {:ok, rows} <- project(dictionary, facets) do
      found = MapSet.new(dictionary, & &1.ordinal)
      missing = for ordinal <- ordinals, not MapSet.member?(found, ordinal), do: {ordinal, false, []}
      {:ok, rows ++ missing}
    end
  end

  def fetch(_ordinals, _facets), do: {:error, :invalid_batch}

  defp dictionary_page(after_ordinal) when is_integer(after_ordinal) and after_ordinal >= 0 do
    dictionary()
    |> Ash.Query.filter(ordinal > ^after_ordinal)
    |> Ash.Query.sort(ordinal: :asc)
    |> Ash.Query.limit(@page_size)
    |> Ash.read()
  end

  defp dictionary do
    DeviceFleetOrdinal
    |> Ash.Query.for_read(:read, %{}, actor: @actor)
    |> Ash.Query.select([:uid, :ordinal, :tombstoned])
    |> Ash.Query.timeout(5_000)
  end

  defp project([], _facets), do: {:ok, []}

  defp project(dictionary, facets) do
    ids = Enum.map(dictionary, & &1.uid)

    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true}, actor: @actor)
      |> Ash.Query.filter(uid in ^ids)
      |> Ash.Query.select([:uid, :type_id, :is_active, :is_available, :deleted_at, :source_retired_at])
      |> Ash.Query.limit(@page_size)
      |> Ash.Query.timeout(5_000)
      |> Ash.Query.calculate(:vendor, :string, expr(fragment("left(btrim(?), 257)", vendor_name)))
      |> Ash.Query.calculate(:bitmap_region, :string, expr(fragment("left(btrim(?), 257)", region)))
      |> Ash.Query.calculate(:vlan, :string, expr(fragment("left(btrim(?), 257)", vlan_uid)))
      |> Ash.Query.calculate(:device_type, :string, expr(fragment("left(btrim(?), 257)", type)))
      |> Ash.Query.calculate(
        :os_name,
        :string,
        expr(fragment("CASE WHEN jsonb_typeof(? -> 'name') = 'string' THEN left(btrim(? ->> 'name'), 257) END", os, os))
      )
      |> Ash.Query.calculate(
        :os_version,
        :string,
        expr(
          fragment("CASE WHEN jsonb_typeof(? -> 'version') = 'string' THEN left(btrim(? ->> 'version'), 257) END", os, os)
        )
      )
      |> Ash.Query.calculate(
        :topology_sighting,
        :boolean,
        expr(get_path(metadata, ["identity_source"]) == "mapper_topology_sighting")
      )
      |> tag_calculations(facets)

    with {:ok, devices} <- query |> Ash.read(page: [limit: @page_size]) |> Page.unwrap() do
      devices = Map.new(devices, &{&1.uid, &1})
      {:ok, Enum.map(dictionary, &row(&1, Map.get(devices, &1.uid), facets))}
    end
  end

  defp tag_calculations(query, facets) do
    Enum.reduce(facets, query, fn
      "tag:" <> key = facet, query ->
        Ash.Query.calculate(
          query,
          facet,
          :string,
          expr(
            fragment(
              "CASE WHEN jsonb_typeof(? -> ?) = 'string' THEN left(btrim(? ->> ?), 257) END",
              tags,
              ^key,
              tags,
              ^key
            )
          )
        )

      _facet, query ->
        query
    end)
  end

  defp row(
         %{ordinal: ordinal, tombstoned: false},
         %{deleted_at: nil, source_retired_at: nil, is_active: active} = device,
         facets
       )
       when active != false do
    values = [
      {"vendor", device.calculations.vendor},
      {"region", device.calculations.bitmap_region},
      {"vlan", device.calculations.vlan},
      {"device_class",
       if(is_nil(device.type_id), do: device.calculations.device_type, else: Integer.to_string(device.type_id))},
      {"os_name", device.calculations.os_name},
      {"os_version", device.calculations.os_version},
      {"availability", availability(device)}
    ]

    tags = for "tag:" <> _ = facet <- facets, do: {facet, Map.get(device.calculations, facet)}

    normalized =
      for {key, value} <- values ++ tags, is_binary(value), value = String.trim(value), value != "", do: {key, value}

    {ordinal, true, normalized}
  end

  defp row(%{ordinal: ordinal}, _device, _facets), do: {ordinal, false, []}

  defp availability(%{calculations: %{topology_sighting: true}}), do: "unknown"
  defp availability(%{is_available: true}), do: "healthy"
  defp availability(%{is_available: false}), do: "unavailable"
  defp availability(_device), do: "unknown"

  defp tag_keys, do: tag_keys(Application.get_env(:serviceradar_web_ng, :bitmap_tag_keys, []))

  @doc "Validates the deployment's explicit device-tag allowlist."
  def tag_keys(keys) do
    if is_list(keys) and length(keys) <= 25 and
         Enum.all?(keys, &(is_binary(&1) and byte_size(&1) in 1..60 and String.valid?(&1))) and
         length(Enum.uniq(keys)) == length(keys) do
      {:ok, keys}
    else
      {:error, :invalid_tag_configuration}
    end
  end
end
