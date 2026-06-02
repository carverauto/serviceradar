defmodule ServiceRadar.Inventory.EndpointInventoryIngestor do
  @moduledoc """
  Ingests endpoint package/SBOM inventory reports from agent result payloads.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.EndpointInventoryArtifactStore
  alias ServiceRadar.Repo

  require Ash.Query

  @collector_name "serviceradar-endpoint-inventory"
  @successful_states ["scanned", "complete", "success"]
  @package_manager_purl_types %{
    "apk" => "apk",
    "dpkg" => "deb",
    "rpm" => "rpm"
  }
  @package_manager_namespaces %{
    "apk" => "alpine",
    "deb" => "debian",
    "dpkg" => "debian",
    "rpm" => "rpm"
  }

  @spec ingest_report(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_report(payload, opts \\ [])

  def ingest_report(payload, opts) when is_map(payload) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:endpoint_inventory_ingestor))

    with {:ok, agent_id} <- required_string(payload, :agent_id),
         {:ok, scan_id} <- required_string(payload, :scan_id),
         {:ok, context} <- build_context(payload, agent_id, scan_id, actor),
         {:ok, artifact} <- maybe_upload_artifact(payload, context, opts) do
      Repo.transaction(fn ->
        scan_ref = upsert_scan(context, artifact)
        replace_artifact(scan_ref, context, artifact)
        package_count = replace_packages(scan_ref, context)
        maybe_promote_current(scan_ref, context)

        %{
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          scan_id: context.scan_id,
          scan_ref: scan_ref,
          package_count: package_count,
          artifact_uploaded?: not is_nil(artifact),
          current?: successful_scan?(context)
        }
      end)
    end
  end

  def ingest_report(_payload, _opts), do: {:error, :invalid_endpoint_inventory_payload}

  defp build_context(payload, agent_id, scan_id, actor) do
    now = DateTime.utc_now()

    device_uid =
      string_value(payload, :device_uid) || resolve_agent_device_uid(agent_id, actor) ||
        existing_scan_device_uid(agent_id)

    packages = normalize_packages(payload)
    sources = normalize_sources(list_value(payload, :sources))

    {:ok,
     %{
       payload: payload,
       agent_id: agent_id,
       scan_id: scan_id,
       device_uid: device_uid,
       collector_name: string_value(payload, :collector_name) || @collector_name,
       collector_version: string_value(payload, :collector_version),
       state: scan_state(payload),
       coverage_state: coverage_state(payload, packages),
       package_count: integer_value(payload, :package_count, length(packages)),
       enabled_sources: enabled_sources(payload, sources),
       manager_counts: manager_counts(packages),
       source_summaries: sources,
       packages: packages,
       last_scan_at:
         datetime_value(payload, :last_scan_at) || datetime_value(payload, :scanned_at) || now,
       last_successful_scan_at: successful_scan_time(payload, now),
       ingested_at: now,
       now: now,
       metadata: metadata(payload)
     }}
  end

  defp maybe_upload_artifact(payload, context, opts) do
    case map_value(payload, :sbom) do
      sbom when map_size(sbom) > 0 ->
        artifact = map_value(payload, :artifact)

        EndpointInventoryArtifactStore.upload_sbom(
          context.agent_id,
          context.scan_id,
          sbom,
          Keyword.put(opts, :expected_sha256, string_value(artifact, :sha256))
        )

      _sbom ->
        {:ok, existing_artifact_ref(payload)}
    end
  end

  defp upsert_scan(context, artifact) do
    row = %{
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      scan_id: context.scan_id,
      collector_name: context.collector_name,
      collector_version: context.collector_version,
      state: context.state,
      coverage_state: context.coverage_state,
      package_count: context.package_count,
      enabled_sources: context.enabled_sources,
      manager_counts: context.manager_counts,
      source_summaries: context.source_summaries,
      artifact_count: if(is_nil(artifact), do: 0, else: 1),
      current: false,
      last_successful_scan_at: context.last_successful_scan_at,
      last_scan_at: context.last_scan_at,
      ingested_at: context.ingested_at,
      metadata: scan_metadata(context),
      inserted_at: context.now,
      updated_at: context.now
    }

    {_, [%{id: id}]} =
      Repo.insert_all(
        "endpoint_inventory_scans",
        [row],
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :device_uid,
             :collector_name,
             :collector_version,
             :state,
             :coverage_state,
             :package_count,
             :enabled_sources,
             :manager_counts,
             :source_summaries,
             :artifact_count,
             :current,
             :last_successful_scan_at,
             :last_scan_at,
             :ingested_at,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:agent_id, :scan_id],
        returning: [:id]
      )

    id
  end

  defp replace_artifact(scan_ref, _context, nil) do
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)
  end

  defp replace_artifact(scan_ref, context, artifact) do
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)

    row = %{
      scan_ref: scan_ref,
      agent_id: context.agent_id,
      device_uid: context.device_uid,
      object_key: Map.fetch!(artifact, :object_key),
      bucket: Map.get(artifact, :bucket),
      domain: Map.get(artifact, :domain),
      content_type: Map.get(artifact, :content_type, "application/json"),
      format: Map.get(artifact, :format, "CycloneDX"),
      spec_version: Map.get(artifact, :spec_version),
      sha256: Map.fetch!(artifact, :sha256),
      size_bytes: Map.get(artifact, :size_bytes, 0),
      storage_backend: Map.get(artifact, :storage_backend, "datasvc_object_store"),
      uploaded_at: Map.get(artifact, :uploaded_at) || context.now,
      metadata: Map.get(artifact, :metadata, %{}),
      inserted_at: context.now
    }

    Repo.insert_all("endpoint_inventory_artifacts", [row],
      prefix: "platform",
      on_conflict:
        {:replace,
         [
           :scan_ref,
           :agent_id,
           :device_uid,
           :bucket,
           :domain,
           :content_type,
           :format,
           :spec_version,
           :sha256,
           :size_bytes,
           :storage_backend,
           :uploaded_at,
           :metadata
         ]},
      conflict_target: [:object_key]
    )
  end

  defp replace_packages(scan_ref, context) do
    delete_scan_rows("endpoint_inventory_packages", scan_ref)

    rows =
      Enum.map(context.packages, fn package ->
        Map.merge(package, %{
          scan_ref: scan_ref,
          device_uid: context.device_uid,
          agent_id: context.agent_id,
          current: false,
          inserted_at: context.now,
          updated_at: context.now
        })
      end)

    if rows != [] do
      Repo.insert_all("endpoint_inventory_packages", rows, prefix: "platform")
    end

    length(rows)
  end

  defp maybe_promote_current(scan_ref, context) do
    if context.state in @successful_states do
      promote_current(scan_ref, context)
    else
      :ok
    end
  end

  defp promote_current(scan_ref, context) do
    now = context.now

    Repo.update_all(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^context.agent_id and s.current == true
      ),
      [set: [current: false, updated_at: now]],
      prefix: "platform"
    )

    Repo.update_all(
      from(p in "endpoint_inventory_packages",
        where: p.agent_id == ^context.agent_id and p.current == true
      ),
      [set: [current: false, updated_at: now]],
      prefix: "platform"
    )

    Repo.update_all(
      from(s in "endpoint_inventory_scans", where: s.id == ^scan_ref),
      [set: [current: true, updated_at: now]],
      prefix: "platform"
    )

    Repo.update_all(
      from(p in "endpoint_inventory_packages", where: p.scan_ref == ^scan_ref),
      [set: [current: true, updated_at: now]],
      prefix: "platform"
    )
  end

  defp successful_scan?(context), do: context.state in @successful_states

  defp delete_scan_rows(table, scan_ref) do
    query = from(r in table, where: r.scan_ref == ^scan_ref)
    Repo.delete_all(query, prefix: "platform")
  end

  defp normalize_packages(payload) do
    payload_packages =
      payload
      |> list_value(:packages)
      |> Enum.map(&normalize_package/1)

    packages =
      if payload_packages == [] do
        payload
        |> map_value(:sbom)
        |> list_value(:components)
        |> Enum.map(&normalize_component/1)
      else
        payload_packages
      end

    packages
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn package ->
      package.purl_canonical ||
        {package.package_manager, package.name, package.version, package.architecture}
    end)
  end

  defp normalize_package(package) when is_map(package) do
    name = string_value(package, :name)
    package_manager = string_value(package, :package_manager) || string_value(package, :manager)

    if name && package_manager do
      %{
        name: name,
        version: string_value(package, :version),
        architecture: string_value(package, :architecture),
        package_manager: package_manager,
        ecosystem: string_value(package, :ecosystem),
        purl: string_value(package, :purl),
        purl_canonical: canonical_purl(package, package_manager),
        cpes: string_list_value(package, :cpes),
        supplier: string_value(package, :supplier),
        license: string_value(package, :license),
        source: string_value(package, :source),
        evidence: map_value(package, :evidence),
        metadata: metadata(package)
      }
    end
  end

  defp normalize_package(_package), do: nil

  defp normalize_component(component) when is_map(component) do
    name = string_value(component, :name)
    properties = properties(component)
    package_manager = Map.get(properties, "serviceradar:package_manager")

    if name && package_manager do
      %{
        name: name,
        version: string_value(component, :version),
        architecture: Map.get(properties, "serviceradar:architecture"),
        package_manager: package_manager,
        ecosystem: Map.get(properties, "serviceradar:ecosystem"),
        purl: string_value(component, :purl),
        purl_canonical: canonical_purl(component, package_manager, properties),
        cpes: component_cpes(component),
        supplier: supplier(component),
        license: license(component),
        source: Map.get(properties, "serviceradar:source"),
        evidence: compact_map(%{"component_type" => string_value(component, :type)}),
        metadata: %{"properties" => properties}
      }
    end
  end

  defp normalize_component(_component), do: nil

  defp canonical_purl(package, package_manager, properties \\ %{}) do
    attrs = %{
      package_manager: package_manager,
      ecosystem:
        string_value(package, :ecosystem) || Map.get(properties, "serviceradar:ecosystem"),
      name: string_value(package, :name),
      version: string_value(package, :version),
      architecture:
        string_value(package, :architecture) || Map.get(properties, "serviceradar:architecture")
    }

    case parse_purl(string_value(package, :purl), attrs) do
      nil -> fallback_purl(attrs)
      canonical -> canonical
    end
  end

  defp parse_purl(nil, _attrs), do: nil

  defp parse_purl("pkg:" <> rest, attrs) do
    {path_and_version, qualifiers} = split_once(rest, "?")
    {path, version} = split_once(path_and_version, "@")
    {type, package_path} = split_once(path, "/")

    type = purl_type(type, attrs.package_manager)

    case package_path_segments(package_path) do
      [] ->
        nil

      segments ->
        name = List.last(segments)

        namespace =
          segments
          |> Enum.drop(-1)
          |> normalize_namespace(type, attrs)

        qualifier_map =
          qualifiers
          |> decode_qualifiers()
          |> Map.put_new("arch", attrs.architecture)
          |> compact_map()

        build_purl(type, namespace, name, version || attrs.version, qualifier_map)
    end
  end

  defp parse_purl(_purl, _attrs), do: nil

  defp fallback_purl(attrs) do
    type = purl_type(attrs.ecosystem, attrs.package_manager)
    namespace = normalize_namespace([], type, attrs)
    qualifiers = compact_map(%{"arch" => attrs.architecture})

    build_purl(type, namespace, attrs.name, attrs.version, qualifiers)
  end

  defp purl_type(type, package_manager) do
    normalized = normalize_token(type) || normalize_token(package_manager)
    Map.get(@package_manager_purl_types, normalized, normalized || "generic")
  end

  defp normalize_namespace([], type, attrs) do
    namespace =
      normalize_token(attrs.ecosystem) ||
        Map.get(@package_manager_namespaces, type) ||
        Map.get(@package_manager_namespaces, normalize_token(attrs.package_manager))

    if namespace, do: [namespace], else: []
  end

  defp normalize_namespace(segments, _type, _attrs) do
    Enum.map(segments, &String.downcase/1)
  end

  defp package_path_segments(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&decode_uri_component/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp package_path_segments(_path), do: []

  defp build_purl(_type, _namespace, nil, _version, _qualifiers), do: nil

  defp build_purl(type, namespace, name, version, qualifiers) do
    path =
      (namespace ++ [name])
      |> Enum.map(&encode_uri_component/1)
      |> Enum.join("/")

    version_part = if version, do: "@#{encode_uri_component(version)}", else: ""
    qualifier_part = encoded_qualifiers(qualifiers)

    "pkg:#{type}/#{path}#{version_part}#{qualifier_part}"
  end

  defp decode_qualifiers(nil), do: %{}

  defp decode_qualifiers(query) do
    query
    |> URI.query_decoder()
    |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
  rescue
    ArgumentError -> %{}
  end

  defp encoded_qualifiers(qualifiers) when map_size(qualifiers) == 0, do: ""

  defp encoded_qualifiers(qualifiers) do
    encoded =
      qualifiers
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("&", fn {key, value} ->
        "#{encode_uri_component(key)}=#{encode_uri_component(value)}"
      end)

    "?#{encoded}"
  end

  defp split_once(value, marker) do
    case String.split(value, marker, parts: 2) do
      [left, right] -> {left, right}
      [left] -> {left, nil}
    end
  end

  defp normalize_token(nil), do: nil

  defp normalize_token(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    if value == "", do: nil, else: value
  end

  defp decode_uri_component(value), do: URI.decode(value)

  defp encode_uri_component(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp normalize_sources(sources) do
    sources
    |> Enum.map(fn
      source when is_map(source) ->
        compact_map(%{
          "source" => string_value(source, :source),
          "state" => string_value(source, :state),
          "package_count" => integer_value(source, :package_count, nil),
          "error" => string_value(source, :error)
        })

      _source ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp enabled_sources(payload, source_summaries) do
    explicit = string_list_value(payload, :enabled_sources)

    if explicit == [] do
      Enum.flat_map(source_summaries, fn summary ->
        case Map.get(summary, "source") do
          source when is_binary(source) and source != "" -> [source]
          _ -> []
        end
      end)
    else
      explicit
    end
  end

  defp manager_counts(packages) do
    packages
    |> Enum.group_by(& &1.package_manager)
    |> Map.new(fn {manager, rows} -> {manager, length(rows)} end)
  end

  defp scan_metadata(context) do
    context.metadata
    |> Map.merge(%{
      "schema_version" => string_value(context.payload, :schema_version),
      "os" => map_value(context.payload, :os),
      "source" => "endpoint_inventory",
      "raw_package_count" => integer_value(context.payload, :package_count, nil)
    })
    |> compact_map()
  end

  defp existing_artifact_ref(payload) do
    artifact = map_value(payload, :artifact)

    object_key = string_value(artifact, :object_key)
    sha256 = string_value(artifact, :sha256)

    if object_key && sha256 do
      %{
        object_key: object_key,
        bucket: string_value(artifact, :bucket),
        domain: string_value(artifact, :domain),
        content_type: string_value(artifact, :content_type) || "application/json",
        format: string_value(artifact, :format) || "CycloneDX",
        spec_version: string_value(artifact, :spec_version),
        sha256: sha256,
        size_bytes: integer_value(artifact, :size_bytes, 0),
        storage_backend: string_value(artifact, :storage_backend) || "datasvc_object_store",
        uploaded_at: unix_datetime(artifact, :uploaded_at_unix),
        metadata: map_value(artifact, :metadata)
      }
    end
  end

  defp resolve_agent_device_uid(agent_id, actor) do
    query = Ash.Query.for_read(Agent, :by_uid, %{uid: agent_id})

    case Ash.read_one(query, actor: actor) do
      {:ok, %{device_uid: device_uid}} when is_binary(device_uid) and device_uid != "" ->
        device_uid

      _ ->
        nil
    end
  end

  defp existing_scan_device_uid(agent_id) do
    query =
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and not is_nil(s.device_uid),
        select: s.device_uid,
        order_by: [desc: s.last_scan_at],
        limit: 1
      )

    Repo.one(query, prefix: "platform")
  end

  defp scan_state(payload) do
    case string_value(payload, :state) || string_value(payload, :status) do
      value when value in ["scanned", "scan_failed", "not_scanned"] -> value
      value when value in ["complete", "success"] -> "scanned"
      "failed" -> "scan_failed"
      _ -> "scanned"
    end
  end

  defp coverage_state(payload, packages) do
    case string_value(payload, :coverage_state) do
      value when value in ["complete", "partial", "not_scanned", "failed"] -> value
      _ when packages == [] -> "not_scanned"
      _ -> "complete"
    end
  end

  defp successful_scan_time(payload, fallback) do
    case scan_state(payload) do
      "scanned" ->
        datetime_value(payload, :last_successful_scan_at) ||
          datetime_value(payload, :last_scan_at) ||
          fallback

      _ ->
        datetime_value(payload, :last_successful_scan_at)
    end
  end

  defp properties(map) do
    map
    |> list_value(:properties)
    |> Map.new(fn
      %{"name" => name, "value" => value} -> {name, value}
      %{name: name, value: value} -> {name, value}
      _ -> {nil, nil}
    end)
    |> Map.delete(nil)
  end

  defp component_cpes(component) do
    cpes = string_list_value(component, :cpes)

    case string_value(component, :cpe) do
      nil -> cpes
      cpe -> Enum.uniq([cpe | cpes])
    end
  end

  defp supplier(component) do
    case map_value(component, :supplier) do
      supplier when map_size(supplier) > 0 -> string_value(supplier, :name)
      _ -> string_value(component, :supplier)
    end
  end

  defp license(component) do
    component
    |> list_value(:licenses)
    |> Enum.find_value(fn
      %{"license" => %{"id" => id}} -> id
      %{"license" => %{"name" => name}} -> name
      %{license: %{id: id}} -> id
      %{license: %{name: name}} -> name
      _ -> nil
    end)
  end

  defp required_string(payload, key) do
    case string_value(payload, key) do
      nil -> {:error, {:missing_required_key, key}}
      value -> {:ok, value}
    end
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp string_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp integer_value(map, key, default) when is_map(map) do
    case value(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp integer_value(_map, _key, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp datetime_value(map, key) when is_map(map) do
    case value(map, key) do
      %DateTime{} = dt ->
        dt

      %NaiveDateTime{} = ndt ->
        DateTime.from_naive!(ndt, "Etc/UTC")

      value when is_integer(value) ->
        DateTime.from_unix!(value)

      value when is_binary(value) ->
        parse_datetime(value)

      _ ->
        nil
    end
  end

  defp datetime_value(_map, _key), do: nil

  defp unix_datetime(map, key) do
    case integer_value(map, key, nil) do
      nil -> nil
      value -> DateTime.from_unix!(value)
    end
  end

  defp parse_datetime(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp list_value(map, key) when is_map(map) do
    case value(map, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp list_value(_map, _key), do: []

  defp string_list_value(map, key) when is_map(map) do
    map
    |> list_value(key)
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: [], else: [value]

      value when is_atom(value) and not is_nil(value) ->
        [Atom.to_string(value)]

      _ ->
        []
    end)
  end

  defp string_list_value(_map, _key), do: []

  defp map_value(map, key) when is_map(map) do
    case value(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_value(_map, _key), do: %{}

  defp metadata(map) when is_map(map), do: map_value(map, :metadata)
  defp metadata(_map), do: %{}

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
