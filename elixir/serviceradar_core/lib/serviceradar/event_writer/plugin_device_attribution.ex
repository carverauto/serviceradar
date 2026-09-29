defmodule ServiceRadar.EventWriter.PluginDeviceAttribution do
  @moduledoc """
  Resolves a plugin's own device reference on an ingested signal to the canonical
  device uid.

  A plugin that discovers devices emits them with `metadata.integration_id` set to
  `<source>:<...>`, which inventory stores as an `integration_id` identifier in the
  device's partition. When the same plugin then emits a metric
  (`MetricResource.device_id`) or an OCSF event (`device.uid`) about that device, it
  can only name it by that same reference; it never learns the `sr:` uid. This
  module maps the reference back, at ingest, for the metrics processor, the events
  processor and alert device resolution.

  ## Scope

  A reference resolves only when all of these hold:

  - it is not already canonical (`sr:` uids pass through untouched) and has the
    shape `<source>:<rest>`;
  - the emitting plugin assignment is known from an attested field -- never from
    the guest-built payload -- and belongs to the attested agent and partition;
  - `<source>` is one of the `integrations.inventory_sources[].source` values the
    assignment's approved plugin package declares, so a plugin cannot attach
    signals to devices another source discovered;
  - an active device carries that `integration_id` in the attested partition.

  Anything else is left exactly as emitted. There is deliberately no fallback to
  the agent's own device: a signal about a device the plugin discovered is not a
  signal about the host the plugin happens to run on.

  The attested plugin identity is:

  - metrics: `ingest_identity.producer_id`, which the agent gateway overwrites with
    the assignment id from the host-set status source `plugin:<assignment id>`
    (gated on the gateway-set `ingest_identity.source == "wasm-plugin"` and a
    non-empty `ingest_identity.attested_by`);
  - events: `metadata.service_radar.plugin_id`, which core's `StatusHandler` sets
    from the same status source, replacing whatever the plugin put there.

  ## Cost

  `resolve/2` takes every reference in one ingest batch at once: one read for the
  assignments, one for their packages, and one identifier read plus one device
  read per partition (chunked). Both the declared sources and the lookup results
  are cached briefly in `DeviceCorrelationCache`, misses for a shorter time, so a
  device discovered after its first signal is picked up within seconds.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.DeviceCorrelationCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query
  require Logger

  # Mirrors the inventory source id rule in `IntegrationDescriptor`.
  @source_regex ~r/^[a-z0-9][a-z0-9_.-]{0,127}$/
  # Bounds each `in` filter. These reads are not capped by a page:
  # Device uses `Ash.stream!/2`, and the others pass `page: false`.
  @read_chunk_size 200
  @wasm_plugin_source "wasm-plugin"

  @typedoc "One device reference, with the attested identity of the plugin that emitted it."
  @type device_reference :: %{
          required(:assignment_id) => String.t() | nil,
          required(:agent_id) => String.t() | nil,
          required(:partition) => String.t() | nil,
          required(:device_ref) => String.t() | nil
        }

  @typedoc "Normalized `{assignment_id, agent_id, partition, device_ref}` key of a reference."
  @type reference_key :: {String.t(), String.t(), String.t(), String.t()}

  @doc """
  The `<source>` prefix of a plugin-scoped device reference, or nil when the value
  is canonical (`sr:`), blank, or not shaped `<source>:<rest>`.
  """
  @spec reference_source(term()) :: String.t() | nil
  def reference_source("sr:" <> _uid), do: nil

  def reference_source(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [source, rest] when rest != "" ->
        if Regex.match?(@source_regex, source), do: source

      _ ->
        nil
    end
  end

  def reference_source(_value), do: nil

  @doc """
  The normalized key `resolve/2` uses for a reference, or nil when the reference
  is incomplete or not plugin-scoped.
  """
  @spec reference_key(device_reference()) :: reference_key() | nil
  def reference_key(reference) when is_map(reference) do
    with assignment_id when is_binary(assignment_id) <- text(reference[:assignment_id]),
         agent_id when is_binary(agent_id) <- text(reference[:agent_id]),
         partition when is_binary(partition) <- text(reference[:partition]),
         device_ref when is_binary(device_ref) <- text(reference[:device_ref]),
         source when is_binary(source) <- reference_source(device_ref) do
      {assignment_id, agent_id, partition, device_ref}
    else
      _ -> nil
    end
  end

  def reference_key(_reference), do: nil

  @doc """
  Resolve a batch of references. Returns `%{reference_key => canonical_uid}` for
  the references that resolved; an unresolved reference is simply absent.

  Best-effort: a lookup failure resolves nothing rather than failing the batch.

  ## Options

  - `:actor` - defaults to a system actor.
  - `:loader` - module answering `load_declared_sources/2` and
    `lookup_partition/3` (default: this module, which reads the database and goes
    through the cache). A custom loader bypasses the cache.
  """
  @spec resolve([device_reference()], keyword()) :: %{reference_key() => String.t()}
  def resolve(references, opts \\ []) when is_list(references) do
    keys =
      references
      |> Enum.map(&reference_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if keys == [] do
      %{}
    else
      context = %{
        actor: Keyword.get(opts, :actor, SystemActor.system(:plugin_device_attribution)),
        loader: Keyword.get(opts, :loader, __MODULE__)
      }

      do_resolve(keys, context)
    end
  rescue
    error ->
      Logger.warning(
        "Plugin device attribution failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      %{}
  end

  @doc """
  Attribute decoded metric rows. A row the metric envelope marked with the
  gateway-attested `:plugin_assignment_id` gets its `device_id` replaced by the
  canonical uid when the reference resolves (the original reference is kept as
  `metadata["plugin_device_ref"]`). The transient marker is removed from every
  row, resolved or not, because it is not a `timeseries_metrics` column.

  `series_key` is left as derived from the attested reference, so a series does
  not split when its device is discovered after its first points.
  """
  @spec attribute_metric_rows([map()], keyword()) :: [map()]
  def attribute_metric_rows(rows, opts \\ []) when is_list(rows) do
    references =
      for %{plugin_assignment_id: _assignment_id} = row <- rows, do: metric_reference(row)

    resolved = if references == [], do: %{}, else: resolve(references, opts)

    Enum.map(rows, fn
      %{plugin_assignment_id: _assignment_id} = row ->
        key = row |> metric_reference() |> reference_key()
        row = Map.delete(row, :plugin_assignment_id)

        case key && Map.get(resolved, key) do
          uid when is_binary(uid) ->
            %{row | device_id: uid, metadata: put_device_ref(row[:metadata], row.device_id)}

          _ ->
            row
        end

      row ->
        row
    end)
  end

  @doc """
  Attribute parsed OCSF event rows: a plugin event whose `device.uid` is a
  resolvable reference gets the canonical uid there. `raw_data` keeps the event
  as emitted.
  """
  @spec attribute_event_rows([map()], keyword()) :: [map()]
  def attribute_event_rows(rows, opts \\ []) when is_list(rows) do
    references =
      rows
      |> Enum.map(&event_reference/1)
      |> Enum.reject(&is_nil/1)

    resolved = if references == [], do: %{}, else: resolve(references, opts)

    if resolved == %{} do
      rows
    else
      Enum.map(rows, &put_event_device_uid(&1, resolved))
    end
  end

  @doc """
  Classify an alert-engine record.

  `{:plugin_reference, uid_or_nil}` when the record is a plugin event whose device
  is a plugin-scoped reference -- the caller must use that answer as-is and not
  fall back to any other correlation (in particular the agent's device).
  `:not_plugin_reference` otherwise.
  """
  @spec attribute_record(map(), keyword()) ::
          {:plugin_reference, String.t() | nil} | :not_plugin_reference
  def attribute_record(record, opts \\ [])

  def attribute_record(record, opts) when is_map(record) do
    case event_reference(record) do
      nil ->
        :not_plugin_reference

      reference ->
        uid =
          case reference_key(reference) do
            nil -> nil
            key -> [reference] |> resolve(opts) |> Map.get(key)
          end

        {:plugin_reference, uid}
    end
  end

  def attribute_record(_record, _opts), do: :not_plugin_reference

  @doc """
  The attested emitting assignment of a decoded metric batch: the gateway-set
  `ingest_identity.producer_id` of a gateway-attested `wasm-plugin` batch.
  """
  @spec metric_batch_assignment_id(map() | nil) :: String.t() | nil
  def metric_batch_assignment_id(%{source: @wasm_plugin_source} = identity) do
    with attested_by when is_binary(attested_by) <- text(Map.get(identity, :attested_by)),
         producer_id when is_binary(producer_id) <- text(Map.get(identity, :producer_id)) do
      producer_id
    else
      _ -> nil
    end
  end

  def metric_batch_assignment_id(_identity), do: nil

  # -- references ---------------------------------------------------------------

  defp metric_reference(row) do
    %{
      assignment_id: row[:plugin_assignment_id],
      agent_id: row[:agent_id],
      partition: row[:partition],
      device_ref: row[:device_id]
    }
  end

  # Only a record carrying the StatusHandler-set plugin identity counts, and only
  # when its device reference is plugin-scoped.
  defp event_reference(row) do
    service_radar = service_radar_metadata(row)
    device_ref = row |> device_map() |> map_get("uid") |> text()

    with assignment_id when is_binary(assignment_id) <- text(map_get(service_radar, "plugin_id")),
         source when is_binary(source) <- reference_source(device_ref) do
      %{
        assignment_id: assignment_id,
        agent_id: map_get(service_radar, "agent_id"),
        partition: map_get(service_radar, "partition_id"),
        device_ref: device_ref
      }
    else
      _ -> nil
    end
  end

  defp put_event_device_uid(row, resolved) do
    with %{} = reference <- event_reference(row),
         key when not is_nil(key) <- reference_key(reference),
         uid when is_binary(uid) <- Map.get(resolved, key) do
      device = row |> device_map() |> Map.put("uid", uid) |> Map.delete(:uid)
      put_field(row, :device, device)
    else
      _ -> row
    end
  end

  defp service_radar_metadata(row) do
    case field(row, :metadata) do
      %{} = metadata -> map_get(metadata, "service_radar") || %{}
      _ -> %{}
    end
  end

  defp device_map(row) do
    case field(row, :device) do
      %{} = device -> device
      _ -> %{}
    end
  end

  defp put_device_ref(%{} = metadata, device_ref),
    do: Map.put(metadata, "plugin_device_ref", device_ref)

  defp put_device_ref(_metadata, device_ref), do: %{"plugin_device_ref" => device_ref}

  # -- resolution ---------------------------------------------------------------

  defp do_resolve(keys, context) do
    sources = declared_sources(keys, context)

    eligible =
      Enum.filter(keys, fn {assignment_id, agent_id, partition, device_ref} ->
        declared = Map.get(sources, {assignment_id, agent_id, partition}, [])
        reference_source(device_ref) in declared
      end)

    uids =
      eligible
      |> Enum.map(fn {_assignment_id, _agent_id, partition, device_ref} ->
        {partition, device_ref}
      end)
      |> Enum.uniq()
      |> device_uids(context)

    Enum.reduce(eligible, %{}, fn {_assignment_id, _agent_id, partition, device_ref} = key, acc ->
      case Map.get(uids, {partition, device_ref}) do
        uid when is_binary(uid) -> Map.put(acc, key, uid)
        _ -> acc
      end
    end)
  end

  # %{{assignment_id, agent_id, partition} => [declared source]}
  defp declared_sources(keys, context) do
    scopes =
      keys
      |> Enum.map(fn {assignment_id, agent_id, partition, _device_ref} ->
        {assignment_id, agent_id, partition}
      end)
      |> Enum.uniq()

    if cached?(context) do
      {cached, misses} =
        Enum.reduce(scopes, {%{}, []}, fn scope, {cached, misses} ->
          case DeviceCorrelationCache.lookup(sources_cache_key(scope)) do
            {:hit, sources} when is_list(sources) -> {Map.put(cached, scope, sources), misses}
            _ -> {cached, [scope | misses]}
          end
        end)

      loaded = load_sources(misses, context)

      Enum.each(loaded, fn {scope, sources} ->
        if sources == [] do
          DeviceCorrelationCache.put(sources_cache_key(scope), nil)
        else
          DeviceCorrelationCache.put_value(sources_cache_key(scope), sources)
        end
      end)

      Map.merge(cached, loaded)
    else
      load_sources(scopes, context)
    end
  end

  defp load_sources([], _context), do: %{}

  defp load_sources(scopes, context),
    do: context.loader.load_declared_sources(scopes, context.actor)

  # %{{partition, device_ref} => canonical uid}
  defp device_uids(pairs, context) do
    if cached?(context) do
      {cached, misses} =
        Enum.reduce(pairs, {%{}, []}, fn pair, {cached, misses} ->
          case DeviceCorrelationCache.lookup(device_cache_key(pair)) do
            {:hit, uid} when is_binary(uid) -> {Map.put(cached, pair, uid), misses}
            :negative -> {cached, misses}
            _ -> {cached, [pair | misses]}
          end
        end)

      loaded = load_uids(misses, context)

      Enum.each(misses, fn pair ->
        DeviceCorrelationCache.put(device_cache_key(pair), Map.get(loaded, pair))
      end)

      Map.merge(cached, loaded)
    else
      load_uids(pairs, context)
    end
  end

  defp load_uids(pairs, context) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(%{}, fn {partition, refs}, acc ->
      Map.merge(acc, context.loader.lookup_partition(partition, refs, context.actor))
    end)
  end

  defp cached?(%{loader: loader}), do: loader == __MODULE__

  @doc false
  # Default loader: `%{{assignment_id, agent_id, partition} => [declared source]}`.
  # A scope declares nothing unless its assignment exists, belongs to that agent
  # and partition, and points at an approved package.
  @spec load_declared_sources([{String.t(), String.t(), String.t()}], term()) :: map()
  def load_declared_sources(scopes, actor) do
    assignments =
      scopes
      |> Enum.map(&elem(&1, 0))
      |> Enum.flat_map(&cast_uuid/1)
      |> Enum.uniq()
      |> read_by_ids(PluginAssignment, actor)
      |> Map.new(&{&1.id, &1})

    sources_by_package =
      assignments
      |> Map.values()
      |> Enum.map(& &1.plugin_package_id)
      |> Enum.uniq()
      |> read_by_ids(PluginPackage, actor)
      |> Map.new(&{&1.id, package_sources(&1)})

    Map.new(scopes, fn {assignment_id, agent_id, partition} = scope ->
      sources =
        with [uuid] <- cast_uuid(assignment_id),
             %PluginAssignment{agent_uid: ^agent_id, partition_id: ^partition} = assignment <-
               Map.get(assignments, uuid) do
          Map.get(sources_by_package, assignment.plugin_package_id, [])
        else
          _ -> []
        end

      {scope, sources}
    end)
  end

  # Only an approved package's manifest declares anything.
  defp package_sources(%PluginPackage{status: :approved, manifest: %{} = manifest}) do
    case Manifest.from_map(manifest) do
      {:ok, parsed} ->
        parsed.integrations
        |> Map.get("inventory_sources", [])
        |> Enum.map(& &1["source"])
        |> Enum.filter(&is_binary/1)

      {:error, _errors} ->
        []
    end
  end

  defp package_sources(_package), do: []

  @doc false
  # Default loader: `%{{partition, device_ref} => canonical uid}` for the refs an
  # active device carries as an `integration_id` in `partition`. A tombstoned
  # device must not absorb live signals, so it does not count.
  @spec lookup_partition(String.t(), [String.t()], term()) :: map()
  def lookup_partition(partition, refs, actor) do
    refs
    |> Enum.chunk_every(@read_chunk_size)
    |> Enum.reduce(%{}, fn chunk, acc ->
      identifiers =
        DeviceIdentifier
        |> Ash.Query.filter(
          identifier_type == :integration_id and partition == ^partition and
            identifier_value in ^chunk
        )
        |> Ash.read!(actor: actor, page: false)

      active =
        identifiers
        |> Enum.map(& &1.device_id)
        |> Enum.uniq()
        |> active_device_uids(actor)

      Enum.reduce(identifiers, acc, fn identifier, acc ->
        if MapSet.member?(active, identifier.device_id) do
          Map.put(acc, {partition, identifier.identifier_value}, identifier.device_id)
        else
          acc
        end
      end)
    end)
  end

  defp active_device_uids([], _actor), do: MapSet.new()

  defp active_device_uids(uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter(uid in ^uids)
    # `Device :read` is paginated; a plain read returns a page struct, not a list.
    |> Ash.stream!(actor: actor)
    |> MapSet.new(& &1.uid)
  end

  defp read_by_ids([], _resource, _actor), do: []

  defp read_by_ids(ids, resource, actor) do
    ids
    |> Enum.chunk_every(@read_chunk_size)
    |> Enum.flat_map(fn chunk ->
      resource
      |> Ash.Query.filter(id in ^chunk)
      |> Ash.read!(actor: actor, page: false)
    end)
  end

  defp sources_cache_key(scope), do: {:plugin_device_attribution_sources, scope}
  defp device_cache_key(pair), do: {:plugin_device_attribution_ref, pair}

  # -- helpers ------------------------------------------------------------------

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp put_field(map, key, value) do
    if Map.has_key?(map, key) or not Map.has_key?(map, Atom.to_string(key)) do
      Map.put(map, key, value)
    else
      Map.put(map, Atom.to_string(key), value)
    end
  end

  defp map_get(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn {k, v} -> if is_atom(k) and Atom.to_string(k) == key, do: v end)
    end
  end

  defp map_get(_map, _key), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
