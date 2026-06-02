defmodule ServiceRadar.Inventory.EndpointInventoryIngestor do
  @moduledoc """
  Ingests endpoint package/SBOM inventory reports from agent result payloads.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadar.Inventory.EndpointInventoryArtifactStore
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @collector_name "serviceradar-endpoint-inventory"
  @hash_algorithm "sha256-v1"
  @hash_algorithm_version 1
  @upload_reason_changed "changed"
  @upload_reason_unchanged "unchanged"
  @package_event_added "added"
  @package_event_removed "removed"
  @package_event_version_changed "version_changed"
  @package_change_signal_schema_version "serviceradar.endpoint_inventory.package_change.v1"
  @risk_source "endpoint_inventory"
  @default_reconcile_floor_scan_count 24
  @default_reconcile_floor_max_age_days 7
  @successful_states ["scanned", "complete", "success", "unchanged"]
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
  @known_cpe_products %{
    "curl" => [{"haxx", "curl"}],
    "libcurl" => [{"haxx", "curl"}],
    "libcurl4" => [{"haxx", "curl"}],
    "libssl" => [{"openssl", "openssl"}],
    "libssl1.1" => [{"openssl", "openssl"}],
    "libssl3" => [{"openssl", "openssl"}],
    "nginx" => [{"nginx", "nginx"}],
    "openssl" => [{"openssl", "openssl"}],
    "openssh" => [{"openbsd", "openssh"}],
    "openssh-client" => [{"openbsd", "openssh"}],
    "openssh-server" => [{"openbsd", "openssh"}],
    "postgresql" => [{"postgresql", "postgresql"}],
    "postgresql-client" => [{"postgresql", "postgresql"}]
  }

  @spec ingest_report(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_report(payload, opts \\ [])

  def ingest_report(payload, opts) when is_map(payload) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:endpoint_inventory_ingestor))

    with {:ok, agent_id} <- required_string(payload, :agent_id),
         {:ok, scan_id} <- required_string(payload, :scan_id),
         {:ok, context} <- build_context(payload, agent_id, scan_id, actor, opts),
         {:ok, artifact} <- maybe_upload_artifact(payload, context, opts) do
      context = apply_artifact_metadata(context, artifact)

      case Repo.transaction(fn ->
             current = current_scan_snapshot(context.agent_id)
             context = apply_hash_freshness(context, current)
             previous_packages = current_package_rows(context)
             scan_ref = upsert_scan(context, artifact)
             replace_artifact(scan_ref, context, artifact)
             package_count = maybe_replace_packages(scan_ref, context)
             history = maybe_record_changed_history(scan_ref, current, previous_packages, context)
             maybe_promote_current(scan_ref, context)

             %{
               agent_id: context.agent_id,
               device_uid: context.device_uid,
               scan_id: context.scan_id,
               scan_ref: scan_ref,
               package_count: package_count,
               artifact_uploaded?: not is_nil(artifact),
               package_rows_replaced?: not context.package_replacement_noop?,
               scan_history_recorded?: history.scan_history_recorded?,
               package_event_count: history.package_event_count,
               package_set_hash_mismatch?: context.package_set_hash_mismatch?,
               reconcile_floor?: context.reconcile_floor_due?,
               directives: scan_ack_directives(context),
               current?: successful_scan?(context),
               package_change_signals: history.package_change_signals
             }
           end) do
        {:ok, result} ->
          published_count =
            result
            |> Map.get(:package_change_signals, [])
            |> publish_package_change_signals(opts)

          {:ok,
           result
           |> Map.delete(:package_change_signals)
           |> Map.put(:package_change_signal_publish_count, published_count)}

        error ->
          error
      end
    end
  end

  def ingest_report(_payload, _opts), do: {:error, :invalid_endpoint_inventory_payload}

  @spec ingest_vulnerability_match(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_vulnerability_match(payload, opts \\ [])

  def ingest_vulnerability_match(payload, opts) when is_map(payload) do
    case vulnerability_match_device_uid(payload) do
      nil ->
        {:ok,
         %{
           risk_contribution_upserted?: false,
           reason: :missing_device_uid
         }}

      device_uid ->
        upsert_vulnerability_risk(device_uid, payload, opts)
    end
  end

  def ingest_vulnerability_match(_payload, _opts),
    do: {:error, :invalid_endpoint_inventory_vulnerability_match_payload}

  defp upsert_vulnerability_risk(device_uid, payload, opts) do
    cvss_score = vulnerability_cvss_score(payload)
    score = cvss_risk_score(cvss_score)
    now = DateTime.utc_now()
    active? = vulnerability_match_active?(payload)

    :ok =
      DeviceRiskReducer.upsert_contribution(
        %{
          device_uid: device_uid,
          source: @risk_source,
          source_ref: device_uid,
          score: score,
          reason: vulnerability_risk_reason(payload, cvss_score),
          active: active?,
          occurred_at: vulnerability_match_time(payload) || now,
          resolved_at: if(active?, do: nil, else: now),
          metadata: vulnerability_risk_metadata(payload, cvss_score, score)
        },
        opts
      )

    {:ok,
     %{
       device_uid: device_uid,
       source: @risk_source,
       source_ref: device_uid,
       score: score,
       active?: active?,
       risk_contribution_upserted?: true
     }}
  end

  defp vulnerability_match_device_uid(payload) do
    string_value(payload, :device_uid) ||
      string_value(payload, :device_id) ||
      payload
      |> map_value(:device)
      |> string_value(:uid)
  end

  defp vulnerability_cvss_score(payload) do
    vulnerability = map_value(payload, :vulnerability)
    advisory = map_value(payload, :advisory)

    first_number_value(payload, [
      :cvss_score,
      :cvssScore,
      :cvss,
      :cvss_base_score,
      :cvssBaseScore
    ]) ||
      first_number_value(vulnerability, [:cvss_score, :cvssScore, :cvss, :base_score, :baseScore]) ||
      first_number_value(advisory, [:cvss_score, :cvssScore, :cvss, :base_score, :baseScore]) ||
      0.0
  end

  defp first_number_value(map, keys) do
    Enum.find_value(keys, &number_value(map, &1))
  end

  defp cvss_risk_score(cvss_score) do
    cvss_score
    |> Kernel.*(10)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp vulnerability_match_active?(payload) do
    case value(payload, :active, :missing) do
      false ->
        false

      value when value in [0] ->
        false

      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 not in ["false", "0"]))

      _ ->
        payload
        |> string_value(:status)
        |> resolved_vulnerability_status?()
        |> Kernel.not()
    end
  end

  defp resolved_vulnerability_status?(nil), do: false

  defp resolved_vulnerability_status?(status) do
    status
    |> String.downcase()
    |> Kernel.in(["fixed", "not_affected", "not_vulnerable", "patched", "removed", "resolved"])
  end

  defp vulnerability_match_time(payload) do
    datetime_value(payload, :observed_at) ||
      datetime_value(payload, :timestamp) ||
      datetime_value(payload, :time)
  end

  defp vulnerability_risk_reason(payload, cvss_score) do
    [
      vulnerability_identifier(payload),
      package_name(payload),
      "CVSS #{format_cvss(cvss_score)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp vulnerability_identifier(payload) do
    vulnerability = map_value(payload, :vulnerability)
    advisory = map_value(payload, :advisory)

    string_value(payload, :cve) ||
      string_value(payload, :cve_id) ||
      string_value(payload, :vulnerability_id) ||
      string_value(vulnerability, :cve) ||
      string_value(vulnerability, :id) ||
      string_value(advisory, :cve) ||
      string_value(advisory, :id)
  end

  defp package_name(payload) do
    package = map_value(payload, :package)

    string_value(payload, :package_name) || string_value(package, :name)
  end

  defp format_cvss(cvss_score) do
    cvss_score
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp vulnerability_risk_metadata(payload, cvss_score, score) do
    compact_map(%{
      "source" => @risk_source,
      "event_id" => string_value(payload, :event_id),
      "agent_id" => string_value(payload, :agent_id),
      "scan_id" => string_value(payload, :scan_id),
      "package_set_hash" => string_value(payload, :package_set_hash),
      "artifact_hash" => string_value(payload, :artifact_hash),
      "cve" => vulnerability_identifier(payload),
      "cvss_score" => cvss_score,
      "risk_score" => score,
      "package" => map_value(payload, :package)
    })
  end

  defp build_context(payload, agent_id, scan_id, actor, opts) do
    now = DateTime.utc_now()

    device_uid =
      string_value(payload, :device_uid) || resolve_agent_device_uid(agent_id, actor) ||
        existing_scan_device_uid(agent_id)

    packages = normalize_packages(payload)
    sources = normalize_sources(list_value(payload, :sources))
    reported_hash = string_value(payload, :package_set_hash)
    server_hash = server_package_set_hash(packages)

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
       reported_package_set_hash: reported_hash,
       package_set_hash: reported_hash || server_hash,
       artifact_hash: string_value(payload, :artifact_hash),
       hash_algorithm: string_value(payload, :hash_algorithm) || @hash_algorithm,
       upload_reason: string_value(payload, :upload_reason) || inferred_upload_reason(payload),
       server_package_set_hash: server_hash,
       package_set_hash_mismatch?: false,
       package_replacement_noop?: false,
       unchanged_scan_count: 0,
       last_changed_scan_at: nil,
       reconcile_floor_due?: false,
       reconcile_floor_scan_count:
         Keyword.get(opts, :reconcile_floor_scan_count, @default_reconcile_floor_scan_count),
       reconcile_floor_max_age_days:
         Keyword.get(opts, :reconcile_floor_max_age_days, @default_reconcile_floor_max_age_days),
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
        artifact_hash = context.artifact_hash

        if artifact_hash do
          case artifact_content_by_hash(artifact_hash) do
            nil ->
              upload_sbom_artifact(payload, context, sbom, opts)

            content ->
              {:ok, artifact_from_content(content, context)}
          end
        else
          upload_sbom_artifact(payload, context, sbom, opts)
        end

      _sbom ->
        {:ok, existing_artifact_ref(payload)}
    end
  end

  defp upload_sbom_artifact(payload, context, sbom, opts) do
    artifact = map_value(payload, :artifact)

    EndpointInventoryArtifactStore.upload_sbom(
      context.agent_id,
      context.scan_id,
      sbom,
      opts
      |> Keyword.put(:expected_sha256, string_value(artifact, :sha256))
      |> Keyword.put(:artifact_hash, context.artifact_hash)
    )
  end

  defp apply_artifact_metadata(context, nil), do: context

  defp apply_artifact_metadata(context, artifact) do
    artifact_hash =
      context.artifact_hash || Map.get(artifact, :artifact_hash) || Map.get(artifact, :sha256)

    %{context | artifact_hash: artifact_hash}
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
      last_changed_scan_at: context.last_changed_scan_at,
      ingested_at: context.ingested_at,
      package_set_hash: context.package_set_hash,
      artifact_hash: context.artifact_hash,
      hash_algorithm: context.hash_algorithm,
      upload_reason: context.upload_reason,
      server_package_set_hash: context.server_package_set_hash,
      package_set_hash_mismatch: context.package_set_hash_mismatch?,
      unchanged_scan_count: context.unchanged_scan_count,
      reconcile_floor_due: context.reconcile_floor_due?,
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
             :last_changed_scan_at,
             :ingested_at,
             :package_set_hash,
             :artifact_hash,
             :hash_algorithm,
             :upload_reason,
             :server_package_set_hash,
             :package_set_hash_mismatch,
             :unchanged_scan_count,
             :reconcile_floor_due,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:agent_id, :scan_id],
        returning: [:id]
      )

    id
  end

  defp replace_artifact(scan_ref, _context, nil) do
    old_content_refs = scan_artifact_content_refs(scan_ref)
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)
    refresh_artifact_content_counts(old_content_refs)
  end

  defp replace_artifact(scan_ref, context, artifact) do
    old_content_refs = scan_artifact_content_refs(scan_ref)
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)
    content = upsert_artifact_content(context, artifact)

    row = %{
      scan_ref: scan_ref,
      artifact_content_ref: content.id,
      agent_id: context.agent_id,
      device_uid: context.device_uid,
      artifact_hash: content.artifact_hash,
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
      reused_content: Map.get(artifact, :reused_content, false) || content.reused?,
      metadata: artifact_provenance_metadata(context, artifact, content),
      inserted_at: context.now
    }

    Repo.insert_all("endpoint_inventory_artifacts", [row], prefix: "platform")
    refresh_artifact_content_counts(Enum.uniq([content.id | old_content_refs]))
  end

  defp replace_packages(scan_ref, context) do
    delete_scan_rows("endpoint_inventory_packages", scan_ref)
    endpoint_package_refs = ensure_endpoint_packages(context.packages, context.now)

    rows =
      Enum.map(context.packages, fn package ->
        Map.merge(package, %{
          scan_ref: scan_ref,
          endpoint_package_ref:
            Map.fetch!(endpoint_package_refs, package_coordinate_key(package)),
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

  defp maybe_replace_packages(_scan_ref, %{package_replacement_noop?: true} = context) do
    context.package_count
  end

  defp maybe_replace_packages(scan_ref, context), do: replace_packages(scan_ref, context)

  defp ensure_endpoint_packages([], _now), do: %{}

  defp ensure_endpoint_packages(packages, now) do
    rows =
      packages
      |> Enum.map(&endpoint_package_row(&1, now))
      |> Enum.uniq_by(& &1.coordinate_key)

    {_count, returned} =
      Repo.insert_all("endpoint_packages", rows,
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :purl_canonical,
             :primary_cpe,
             :cpes,
             :package_manager,
             :name,
             :version,
             :architecture,
             :ecosystem,
             :source_scope,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:coordinate_key],
        returning: [:id, :coordinate_key]
      )

    Map.new(returned, fn row -> {row.coordinate_key, row.id} end)
  end

  defp endpoint_package_row(package, now) do
    cpes = normalize_cpes(Map.get(package, :cpes, []))

    %{
      coordinate_key: package_coordinate_key(package),
      purl_canonical: package.purl_canonical,
      primary_cpe: List.first(cpes),
      cpes: cpes,
      package_manager: package.package_manager,
      name: package.name,
      version: package.version,
      architecture: package.architecture,
      ecosystem: package.ecosystem,
      source_scope: "host",
      metadata: endpoint_package_metadata(package, cpes),
      inserted_at: now,
      updated_at: now
    }
  end

  defp endpoint_package_metadata(package, cpes) do
    %{
      "source" => "endpoint_inventory",
      "match_input" =>
        compact_map(%{
          "scope" => "host",
          "canonical_purl" => trimmed_or_nil(package.purl_canonical),
          "candidate_cpes" => cpes,
          "fallback_tuple" =>
            compact_map(%{
              "package_manager" => trimmed_or_nil(package.package_manager),
              "name" => trimmed_or_nil(package.name),
              "version" => trimmed_or_nil(package.version),
              "architecture" => trimmed_or_nil(package.architecture)
            })
        })
    }
  end

  defp package_coordinate_key(package) do
    case trimmed(package.purl_canonical) do
      "" ->
        fallback_coordinate_key(package)

      purl_canonical ->
        "purl:#{purl_canonical}"
    end
  end

  defp fallback_coordinate_key(package) do
    encoded =
      [
        trimmed(package.package_manager),
        trimmed(package.name),
        trimmed(package.version),
        trimmed(package.architecture)
      ]
      |> Enum.join("\u0000")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "fallback:#{encoded}"
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

    if not context.package_replacement_noop? do
      Repo.update_all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^context.agent_id and p.current == true
        ),
        [set: [current: false, updated_at: now]],
        prefix: "platform"
      )
    end

    Repo.update_all(
      from(s in "endpoint_inventory_scans", where: s.id == ^scan_ref),
      [set: [current: true, updated_at: now]],
      prefix: "platform"
    )

    if not context.package_replacement_noop? do
      Repo.update_all(
        from(p in "endpoint_inventory_packages", where: p.scan_ref == ^scan_ref),
        [set: [current: true, updated_at: now]],
        prefix: "platform"
      )
    end
  end

  defp successful_scan?(context), do: context.state in @successful_states

  defp current_scan_snapshot(agent_id) do
    Repo.one(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == true,
        select: %{
          id: s.id,
          package_count: s.package_count,
          scan_id: s.scan_id,
          package_set_hash: s.package_set_hash,
          server_package_set_hash: s.server_package_set_hash,
          last_changed_scan_at: s.last_changed_scan_at,
          unchanged_scan_count: s.unchanged_scan_count
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp current_package_rows(%{package_replacement_noop?: true}), do: []

  defp current_package_rows(context) do
    if successful_scan?(context) do
      Repo.all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^context.agent_id and p.current == true,
          select: %{
            name: p.name,
            version: p.version,
            architecture: p.architecture,
            package_manager: p.package_manager,
            ecosystem: p.ecosystem,
            purl: p.purl,
            purl_canonical: p.purl_canonical,
            cpes: p.cpes,
            supplier: p.supplier,
            license: p.license,
            source: p.source,
            evidence: p.evidence,
            metadata: p.metadata
          }
        ),
        prefix: "platform"
      )
    else
      []
    end
  end

  defp maybe_record_changed_history(scan_ref, current, previous_packages, context) do
    if record_changed_history?(context) do
      package_events = package_diff_events(previous_packages, context.packages)

      {package_event_count, package_event_rows} =
        insert_package_events(scan_ref, current, package_events, context)

      apply_current_count_changes(package_events, context)

      insert_scan_history(scan_ref, current, package_event_count, context)

      %{
        scan_history_recorded?: true,
        package_event_count: package_event_count,
        package_change_signals: Enum.map(package_event_rows, &package_change_signal/1)
      }
    else
      %{scan_history_recorded?: false, package_event_count: 0, package_change_signals: []}
    end
  end

  defp record_changed_history?(context) do
    successful_scan?(context) and not context.package_replacement_noop?
  end

  defp insert_scan_history(scan_ref, current, package_event_count, context) do
    row = %{
      scan_time: changed_scan_time(context),
      scan_ref: scan_ref,
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
      artifact_count: if(is_nil(context.artifact_hash), do: 0, else: 1),
      package_set_hash: context.package_set_hash,
      previous_package_set_hash: Map.get(current || %{}, :package_set_hash),
      server_package_set_hash: context.server_package_set_hash,
      artifact_hash: context.artifact_hash,
      hash_algorithm: context.hash_algorithm,
      upload_reason: context.upload_reason,
      package_set_hash_mismatch: context.package_set_hash_mismatch?,
      package_event_count: package_event_count,
      metadata: scan_history_metadata(current, context),
      inserted_at: context.now
    }

    Repo.insert_all("endpoint_inventory_scan_history", [row], prefix: "platform")
  end

  defp insert_package_events(_scan_ref, _current, [], _context), do: {0, []}

  defp insert_package_events(scan_ref, current, package_events, context) do
    scan_time = changed_scan_time(context)

    rows =
      Enum.map(package_events, fn event ->
        package_event_row(scan_ref, current, event, scan_time, context)
      end)

    {count, _rows} =
      Repo.insert_all("endpoint_inventory_package_events", rows,
        prefix: "platform",
        on_conflict: :nothing,
        conflict_target: [:scan_time, :event_id]
      )

    {count, rows}
  end

  defp package_change_signal(row) do
    event_type = Map.fetch!(row, :event_type)

    %{
      subject: "signals.causal.inventory.#{event_type}",
      payload: %{
        "schema_version" => @package_change_signal_schema_version,
        "event_id" => row.event_id,
        "signal_type" => "inventory",
        "signal_domain" => "inventory",
        "event_type" => event_type,
        "timestamp" => DateTime.to_iso8601(row.scan_time),
        "observed_at" => DateTime.to_iso8601(row.scan_time),
        "severity" => "informational",
        "message" => package_change_message(event_type, row),
        "agent_id" => row.agent_id,
        "device_uid" => row.device_uid,
        "device_id" => row.device_uid,
        "scan_id" => row.scan_id,
        "package_set_hash" => row.package_set_hash,
        "previous_package_set_hash" => row.previous_package_set_hash,
        "artifact_hash" => row.artifact_hash,
        "package" => package_change_package(row),
        "previous_package" => previous_package(row)
      }
    }
  end

  defp package_change_message(@package_event_added, row),
    do: "endpoint package added: #{row.name}"

  defp package_change_message(@package_event_removed, row),
    do: "endpoint package removed: #{row.name}"

  defp package_change_message(@package_event_version_changed, row),
    do: "endpoint package version changed: #{row.name}"

  defp package_change_message(_event_type, row), do: "endpoint package changed: #{row.name}"

  defp package_change_package(row) do
    compact_map(%{
      "package_manager" => row.package_manager,
      "ecosystem" => row.ecosystem,
      "name" => row.name,
      "architecture" => row.architecture,
      "version" => row.version,
      "previous_version" => row.previous_version,
      "new_version" => row.new_version,
      "purl" => row.purl,
      "purl_canonical" => row.purl_canonical,
      "previous_purl" => row.previous_purl,
      "previous_purl_canonical" => row.previous_purl_canonical,
      "cpes" => row.cpes || [],
      "coordinate_hash" => row.coordinate_hash
    })
  end

  defp previous_package(%{
         previous_version: nil,
         previous_purl: nil,
         previous_purl_canonical: nil
       }), do: nil

  defp previous_package(row) do
    compact_map(%{
      "package_manager" => row.package_manager,
      "ecosystem" => row.ecosystem,
      "name" => row.name,
      "architecture" => row.architecture,
      "version" => row.previous_version,
      "purl" => row.previous_purl,
      "purl_canonical" => row.previous_purl_canonical
    })
  end

  defp publish_package_change_signals([], _opts), do: 0

  defp publish_package_change_signals(signals, opts) do
    publisher = Keyword.get(opts, :causal_signal_publisher, {Connection, :publish, []})

    Enum.reduce(signals, 0, fn %{subject: subject, payload: payload}, count ->
      encoded = Jason.encode!(payload)

      case publish_causal_signal(publisher, subject, encoded) do
        :ok ->
          count + 1

        {:error, reason} ->
          Logger.warning(
            "Endpoint inventory causal signal publish failed: subject=#{subject} reason=#{inspect(reason)}"
          )

          count
      end
    end)
  end

  defp publish_causal_signal(fun, subject, payload) when is_function(fun, 2) do
    fun.(subject, payload)
  end

  defp publish_causal_signal({module, function, extra_args}, subject, payload) do
    apply(module, function, [subject, payload | extra_args])
  end

  defp package_diff_events(previous_packages, packages) do
    previous_by_key = Map.new(previous_packages, &{package_identity_key(&1), &1})
    current_by_key = Map.new(packages, &{package_identity_key(&1), &1})

    added =
      current_by_key
      |> Map.drop(Map.keys(previous_by_key))
      |> Map.values()
      |> Enum.map(&%{event_type: @package_event_added, package: &1})

    removed =
      previous_by_key
      |> Map.drop(Map.keys(current_by_key))
      |> Map.values()
      |> Enum.map(&%{event_type: @package_event_removed, previous_package: &1})

    version_changed =
      previous_by_key
      |> Map.take(Map.keys(current_by_key))
      |> Enum.flat_map(fn {key, previous_package} ->
        package = Map.fetch!(current_by_key, key)

        if package_version_changed?(previous_package, package) do
          [
            %{
              event_type: @package_event_version_changed,
              previous_package: previous_package,
              package: package
            }
          ]
        else
          []
        end
      end)

    added ++ removed ++ version_changed
  end

  defp package_event_row(scan_ref, current, event, scan_time, context) do
    package = Map.get(event, :package) || Map.fetch!(event, :previous_package)
    previous_package = Map.get(event, :previous_package)
    event_type = Map.fetch!(event, :event_type)
    event_hash = package_event_coordinate_hash(event)

    %{
      event_id: package_event_id(context, event_type, event_hash),
      scan_time: scan_time,
      scan_ref: scan_ref,
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      scan_id: context.scan_id,
      event_type: event_type,
      package_manager: package.package_manager,
      ecosystem: package.ecosystem,
      name: package.name,
      architecture: package.architecture,
      version: package.version,
      previous_version: Map.get(previous_package || %{}, :version),
      new_version: Map.get(event[:package] || %{}, :version),
      purl: package.purl,
      purl_canonical: package.purl_canonical,
      previous_purl: Map.get(previous_package || %{}, :purl),
      previous_purl_canonical: Map.get(previous_package || %{}, :purl_canonical),
      cpes: package.cpes || [],
      coordinate_hash: package_coordinate_hash(package),
      package_set_hash: context.package_set_hash,
      previous_package_set_hash: Map.get(current || %{}, :package_set_hash),
      artifact_hash: context.artifact_hash,
      metadata: package_event_metadata(event, context),
      inserted_at: context.now
    }
  end

  defp changed_scan_time(context) do
    context.last_successful_scan_at || context.last_scan_at || context.now
  end

  defp scan_history_metadata(current, context) do
    context.metadata
    |> Map.merge(%{
      "previous_scan_ref" => encode_uuid(Map.get(current || %{}, :id)),
      "previous_scan_id" => Map.get(current || %{}, :scan_id),
      "source" => "endpoint_inventory_history"
    })
    |> compact_map()
  end

  defp package_event_metadata(event, context) do
    event
    |> Map.take([:event_type])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{
      "source" => "endpoint_inventory_diff",
      "package_set_hash" => context.package_set_hash,
      "artifact_hash" => context.artifact_hash
    })
    |> compact_map()
  end

  defp apply_current_count_changes([], _context), do: :ok

  defp apply_current_count_changes(package_events, context) do
    package_events
    |> Enum.flat_map(&package_count_changes/1)
    |> Enum.each(fn {package, delta, event} ->
      event_id = package_count_event_id(context, event, package, delta)
      host_count = upsert_current_package_count(package, delta, context)
      insert_package_count_history(package, delta, host_count, event_id, context)

      package
      |> Map.get(:cpes, [])
      |> Enum.uniq()
      |> Enum.reject(&is_blank?/1)
      |> Enum.each(fn cpe ->
        cpe_host_count = upsert_current_cpe_count(cpe, delta, context)
        insert_cpe_count_history(cpe, delta, cpe_host_count, event_id, context)
      end)
    end)

    :ok
  end

  defp package_count_changes(%{event_type: @package_event_added, package: package} = event) do
    [{package, 1, event}]
  end

  defp package_count_changes(
         %{event_type: @package_event_removed, previous_package: package} = event
       ) do
    [{package, -1, event}]
  end

  defp package_count_changes(
         %{
           event_type: @package_event_version_changed,
           previous_package: previous_package,
           package: package
         } = event
       ) do
    [{previous_package, -1, event}, {package, 1, event}]
  end

  defp upsert_current_package_count(package, delta, context) do
    coordinate_hash = package_coordinate_hash(package)

    %{rows: [[host_count]]} =
      Repo.query!(
        """
        INSERT INTO platform.endpoint_inventory_current_package_counts (
          coordinate_hash,
          package_manager,
          ecosystem,
          name,
          version,
          architecture,
          purl_canonical,
          cpes,
          host_count,
          first_seen_at,
          last_seen_at,
          updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, GREATEST($9::integer, 0), $10, $10, $10)
        ON CONFLICT (coordinate_hash) DO UPDATE SET
          package_manager = EXCLUDED.package_manager,
          ecosystem = EXCLUDED.ecosystem,
          name = EXCLUDED.name,
          version = EXCLUDED.version,
          architecture = EXCLUDED.architecture,
          purl_canonical = EXCLUDED.purl_canonical,
          cpes = EXCLUDED.cpes,
          host_count = GREATEST(0, endpoint_inventory_current_package_counts.host_count + $9::integer),
          last_seen_at = $10,
          updated_at = $10
        RETURNING host_count
        """,
        [
          coordinate_hash,
          package.package_manager,
          package.ecosystem,
          package.name,
          package.version,
          package.architecture,
          package.purl_canonical,
          package.cpes || [],
          delta,
          context.now
        ]
      )

    host_count
  end

  defp insert_package_count_history(package, delta, host_count, event_id, context) do
    Repo.insert_all(
      "endpoint_inventory_package_count_history",
      [
        %{
          scan_time: changed_scan_time(context),
          event_id: event_id,
          coordinate_hash: package_coordinate_hash(package),
          package_manager: package.package_manager,
          ecosystem: package.ecosystem,
          name: package.name,
          version: package.version,
          architecture: package.architecture,
          purl_canonical: package.purl_canonical,
          cpes: package.cpes || [],
          host_count: host_count,
          count_delta: delta,
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          scan_id: context.scan_id,
          inserted_at: context.now
        }
      ],
      prefix: "platform"
    )
  end

  defp upsert_current_cpe_count(cpe, delta, context) do
    %{rows: [[host_count]]} =
      Repo.query!(
        """
        INSERT INTO platform.endpoint_inventory_current_cpe_counts (
          cpe,
          host_count,
          first_seen_at,
          last_seen_at,
          updated_at
        )
        VALUES ($1, GREATEST($2::integer, 0), $3, $3, $3)
        ON CONFLICT (cpe) DO UPDATE SET
          host_count = GREATEST(0, endpoint_inventory_current_cpe_counts.host_count + $2::integer),
          last_seen_at = $3,
          updated_at = $3
        RETURNING host_count
        """,
        [cpe, delta, context.now]
      )

    host_count
  end

  defp insert_cpe_count_history(cpe, delta, host_count, event_id, context) do
    Repo.insert_all(
      "endpoint_inventory_cpe_count_history",
      [
        %{
          scan_time: changed_scan_time(context),
          event_id: event_id,
          cpe: cpe,
          host_count: host_count,
          count_delta: delta,
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          scan_id: context.scan_id,
          inserted_at: context.now
        }
      ],
      prefix: "platform"
    )
  end

  defp package_identity_key(package) do
    Enum.join(
      [
        normalized_coordinate_value(package.package_manager),
        normalized_coordinate_value(package.name),
        normalized_coordinate_value(package.architecture),
        normalized_coordinate_value(package.ecosystem)
      ],
      <<0>>
    )
  end

  defp package_version_changed?(previous_package, package) do
    normalized_coordinate_value(previous_package.version) !=
      normalized_coordinate_value(package.version) or
      normalized_coordinate_value(previous_package.purl_canonical) !=
        normalized_coordinate_value(package.purl_canonical)
  end

  defp package_event_coordinate_hash(event) do
    parts =
      [
        event.event_type,
        package_coordinate_fragment(Map.get(event, :previous_package)),
        package_coordinate_fragment(Map.get(event, :package))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(<<0>>)

    :sha256
    |> :crypto.hash(parts)
    |> Base.encode16(case: :lower)
  end

  defp package_coordinate_hash(package) do
    package
    |> package_coordinate_fragment()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp package_coordinate_fragment(nil), do: nil

  defp package_coordinate_fragment(package) do
    Enum.map_join(
      [
        package.package_manager,
        package.name,
        package.version,
        package.architecture,
        package.ecosystem,
        package.purl_canonical
      ],
      <<0>>,
      &normalized_coordinate_value/1
    )
  end

  defp package_event_id(context, event_type, coordinate_hash) do
    "inventory:#{context.agent_id}:#{context.scan_id}:#{event_type}:#{coordinate_hash}"
  end

  defp package_count_event_id(context, event, package, delta) do
    delta_key = if delta > 0, do: "inc", else: "dec"
    coordinate_hash = package_coordinate_hash(package)

    "inventory-count:#{context.agent_id}:#{context.scan_id}:#{event.event_type}:#{delta_key}:#{coordinate_hash}"
  end

  defp normalized_coordinate_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalized_coordinate_value(nil), do: ""

  defp normalized_coordinate_value(value),
    do: value |> to_string() |> normalized_coordinate_value()

  defp is_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp is_blank?(nil), do: true
  defp is_blank?(_value), do: false

  defp apply_hash_freshness(context, current) do
    package_replacement_noop? = package_replacement_noop?(context, current)
    server_hash = effective_server_package_set_hash(context, current, package_replacement_noop?)
    mismatch? = package_set_hash_mismatch?(context.reported_package_set_hash, server_hash)

    package_set_hash =
      effective_package_set_hash(context, current, package_replacement_noop?, server_hash)

    unchanged_count = unchanged_scan_count(context, current, package_replacement_noop?)
    last_changed_at = last_changed_scan_at(context, current, package_replacement_noop?)
    reconcile_floor_due? = reconcile_floor_due?(context, last_changed_at, unchanged_count)

    if mismatch? do
      Logger.warning(
        "Endpoint inventory package_set_hash mismatch: agent_id=#{context.agent_id} scan_id=#{context.scan_id} reported=#{context.reported_package_set_hash} server=#{server_hash}"
      )
    end

    %{
      context
      | package_set_hash: package_set_hash,
        server_package_set_hash: server_hash,
        package_set_hash_mismatch?: mismatch?,
        package_replacement_noop?: package_replacement_noop?,
        unchanged_scan_count: unchanged_count,
        last_changed_scan_at: last_changed_at,
        reconcile_floor_due?: reconcile_floor_due?
    }
  end

  defp package_replacement_noop?(context, current) do
    successful_scan?(context) and not is_nil(current) and
      reported_package_set_hash(context) not in [nil, ""] and
      reported_package_set_hash(context) == current.package_set_hash and
      context.upload_reason == @upload_reason_unchanged
  end

  defp reported_package_set_hash(context) do
    context.reported_package_set_hash || context.package_set_hash
  end

  defp effective_server_package_set_hash(context, current, true) do
    context.server_package_set_hash || Map.get(current || %{}, :server_package_set_hash) ||
      Map.get(current || %{}, :package_set_hash)
  end

  defp effective_server_package_set_hash(context, _current, false) do
    context.server_package_set_hash
  end

  defp effective_package_set_hash(context, current, true, _server_hash) do
    reported_package_set_hash(context) || Map.get(current || %{}, :package_set_hash)
  end

  defp effective_package_set_hash(context, _current, false, server_hash) do
    server_hash || reported_package_set_hash(context)
  end

  defp package_set_hash_mismatch?(nil, _server_hash), do: false
  defp package_set_hash_mismatch?(_package_set_hash, nil), do: false

  defp package_set_hash_mismatch?(package_set_hash, server_hash),
    do: package_set_hash != server_hash

  defp unchanged_scan_count(_context, current, true) do
    Map.get(current || %{}, :unchanged_scan_count, 0) + 1
  end

  defp unchanged_scan_count(context, _current, false) do
    if successful_scan?(context), do: 0, else: 0
  end

  defp last_changed_scan_at(_context, current, true) do
    Map.get(current || %{}, :last_changed_scan_at)
  end

  defp last_changed_scan_at(context, _current, false) do
    if successful_scan?(context) and changed_upload?(context) do
      context.last_successful_scan_at || context.last_scan_at
    end
  end

  defp changed_upload?(context), do: context.upload_reason != @upload_reason_unchanged

  defp reconcile_floor_due?(context, last_changed_at, unchanged_scan_count) do
    successful_scan?(context) and context.upload_reason == @upload_reason_unchanged and
      (scan_floor_due?(context.reconcile_floor_scan_count, unchanged_scan_count) or
         age_floor_due?(context, last_changed_at))
  end

  defp scan_floor_due?(scan_count_floor, unchanged_scan_count)
       when is_integer(scan_count_floor) and scan_count_floor > 0 do
    unchanged_scan_count >= scan_count_floor
  end

  defp scan_floor_due?(_scan_count_floor, _unchanged_scan_count), do: false

  defp age_floor_due?(context, %DateTime{} = last_changed_at) do
    max_age_days = context.reconcile_floor_max_age_days

    is_integer(max_age_days) and max_age_days > 0 and
      DateTime.diff(context.last_scan_at, last_changed_at, :day) >= max_age_days
  end

  defp age_floor_due?(_context, _last_changed_at), do: false

  defp scan_ack_directives(%{reconcile_floor_due?: true}) do
    %{
      "endpoint_inventory" => %{
        "reconcile_floor" => true,
        "upload_reason" => @upload_reason_changed,
        "message" => "server reconcile floor reached; next scan must perform a full upload"
      }
    }
  end

  defp scan_ack_directives(_context), do: %{}

  defp delete_scan_rows(table, scan_ref) do
    query = from(r in table, where: r.scan_ref == ^scan_ref)
    Repo.delete_all(query, prefix: "platform")
  end

  defp artifact_content_by_hash(nil), do: nil
  defp artifact_content_by_hash(""), do: nil

  defp artifact_content_by_hash(artifact_hash) do
    Repo.one(
      from(c in "endpoint_inventory_artifact_contents",
        where: c.artifact_hash == ^artifact_hash,
        select: %{
          id: c.id,
          artifact_hash: c.artifact_hash,
          object_key: c.object_key,
          bucket: c.bucket,
          domain: c.domain,
          content_type: c.content_type,
          format: c.format,
          spec_version: c.spec_version,
          sha256: c.sha256,
          size_bytes: c.size_bytes,
          storage_backend: c.storage_backend,
          first_uploaded_at: c.first_uploaded_at,
          metadata: c.metadata
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp artifact_from_content(content, context) do
    %{
      artifact_content_ref: content.id,
      artifact_hash: content.artifact_hash,
      object_key: content.object_key,
      bucket: content.bucket,
      domain: content.domain,
      content_type: content.content_type,
      format: content.format,
      spec_version: content.spec_version,
      sha256: content.sha256,
      size_bytes: content.size_bytes,
      storage_backend: content.storage_backend,
      uploaded_at: content.first_uploaded_at || context.now,
      reused_content: true,
      metadata: Map.get(content, :metadata, %{})
    }
  end

  defp upsert_artifact_content(context, artifact) do
    artifact_hash = artifact_hash_for(context, artifact)
    existing = artifact_content_by_hash(artifact_hash)

    row = %{
      artifact_hash: artifact_hash,
      object_key: Map.fetch!(artifact, :object_key),
      bucket: Map.get(artifact, :bucket),
      domain: Map.get(artifact, :domain),
      content_type: Map.get(artifact, :content_type, "application/json"),
      format: Map.get(artifact, :format, "CycloneDX"),
      spec_version: Map.get(artifact, :spec_version),
      sha256: Map.fetch!(artifact, :sha256),
      size_bytes: Map.get(artifact, :size_bytes, 0),
      storage_backend: Map.get(artifact, :storage_backend, "datasvc_object_store"),
      first_uploaded_at: Map.get(artifact, :uploaded_at) || context.now,
      last_referenced_at: context.now,
      reference_count: 0,
      metadata: artifact_content_metadata(artifact),
      inserted_at: context.now,
      updated_at: context.now
    }

    {_, [%{id: id}]} =
      Repo.insert_all("endpoint_inventory_artifact_contents", [row],
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :object_key,
             :bucket,
             :domain,
             :content_type,
             :format,
             :spec_version,
             :sha256,
             :size_bytes,
             :storage_backend,
             :last_referenced_at,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:artifact_hash],
        returning: [:id]
      )

    %{id: id, artifact_hash: artifact_hash, reused?: not is_nil(existing)}
  end

  defp artifact_hash_for(context, artifact) do
    context.artifact_hash || Map.get(artifact, :artifact_hash) || Map.fetch!(artifact, :sha256)
  end

  defp artifact_content_metadata(artifact) do
    artifact_hash = Map.get(artifact, :artifact_hash) || Map.get(artifact, :sha256)

    artifact
    |> Map.get(:metadata, %{})
    |> Map.drop(["agent_id", "scan_id", :agent_id, :scan_id])
    |> Map.merge(%{
      "source" => "endpoint_inventory",
      "artifact_hash" => artifact_hash
    })
    |> compact_map()
  end

  defp artifact_provenance_metadata(context, artifact, content) do
    artifact
    |> Map.get(:metadata, %{})
    |> Map.merge(%{
      "agent_id" => context.agent_id,
      "scan_id" => context.scan_id,
      "upload_reason" => context.upload_reason,
      "artifact_hash" => content.artifact_hash,
      "artifact_content_ref" => encode_uuid(content.id),
      "reused_content" => Map.get(artifact, :reused_content, false) || content.reused?
    })
    |> compact_map()
  end

  defp encode_uuid(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    case Ecto.UUID.load(uuid) do
      {:ok, encoded} -> encoded
      :error -> Base.encode16(uuid, case: :lower)
    end
  end

  defp encode_uuid(uuid), do: uuid

  defp scan_artifact_content_refs(scan_ref) do
    Repo.all(
      from(a in "endpoint_inventory_artifacts",
        where: a.scan_ref == ^scan_ref and not is_nil(a.artifact_content_ref),
        select: a.artifact_content_ref
      ),
      prefix: "platform"
    )
  end

  defp refresh_artifact_content_counts(content_refs) do
    content_refs
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn content_ref ->
      count =
        Repo.one!(
          from(a in "endpoint_inventory_artifacts",
            where: a.artifact_content_ref == ^content_ref,
            select: count(a.id)
          ),
          prefix: "platform"
        )

      Repo.update_all(
        from(c in "endpoint_inventory_artifact_contents", where: c.id == ^content_ref),
        [
          set: [
            reference_count: count,
            last_referenced_at: if(count > 0, do: DateTime.utc_now()),
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: "platform"
      )
    end)
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
      purl_canonical = canonical_purl(package, package_manager)

      %{
        name: name,
        version: string_value(package, :version),
        architecture: string_value(package, :architecture),
        package_manager: package_manager,
        ecosystem: string_value(package, :ecosystem),
        purl: string_value(package, :purl),
        purl_canonical: purl_canonical,
        cpes:
          package
          |> string_list_value(:cpes)
          |> candidate_cpes(name, string_value(package, :version)),
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
      purl_canonical = canonical_purl(component, package_manager, properties)
      version = string_value(component, :version)

      %{
        name: name,
        version: version,
        architecture: Map.get(properties, "serviceradar:architecture"),
        package_manager: package_manager,
        ecosystem: Map.get(properties, "serviceradar:ecosystem"),
        purl: string_value(component, :purl),
        purl_canonical: purl_canonical,
        cpes:
          component
          |> component_cpes()
          |> candidate_cpes(name, version),
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
      Map.get(@package_manager_namespaces, type) ||
        Map.get(@package_manager_namespaces, normalize_token(attrs.package_manager)) ||
        normalize_token(attrs.ecosystem)

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
    path = Enum.map_join(namespace ++ [name], "/", &encode_uri_component/1)

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

  defp server_package_set_hash([]), do: nil

  defp server_package_set_hash(packages) do
    lines =
      packages
      |> Enum.flat_map(&package_hash_line/1)
      |> Enum.sort()

    payload = Enum.join(lines, "\n")

    :sha256
    |> :crypto.hash([<<@hash_algorithm_version>>, payload])
    |> Base.encode16(case: :lower)
  end

  defp package_hash_line(package) do
    name = trimmed(package.name)
    package_manager = trimmed(package.package_manager)

    if name == "" or package_manager == "" do
      []
    else
      [
        IO.iodata_to_binary([
          "{\"package_manager\":",
          json_string(package_manager),
          ",\"name\":",
          json_string(name),
          ",\"version\":",
          json_string(trimmed(package.version)),
          ",\"architecture\":",
          json_string(trimmed(package.architecture)),
          ",\"purl_canonical\":",
          json_string(trimmed(package.purl_canonical)),
          "}"
        ])
      ]
    end
  end

  defp scan_metadata(context) do
    context.metadata
    |> Map.merge(%{
      "schema_version" => string_value(context.payload, :schema_version),
      "os" => map_value(context.payload, :os),
      "source" => "endpoint_inventory",
      "reported_package_set_hash" => context.reported_package_set_hash,
      "package_set_hash" => context.package_set_hash,
      "artifact_hash" => context.artifact_hash,
      "hash_algorithm" => context.hash_algorithm,
      "upload_reason" => context.upload_reason,
      "server_package_set_hash" => context.server_package_set_hash,
      "package_set_hash_mismatch" => context.package_set_hash_mismatch?,
      "unchanged_scan_count" => context.unchanged_scan_count,
      "last_changed_scan_at" => iso8601(context.last_changed_scan_at),
      "reconcile_floor_due" => context.reconcile_floor_due?,
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
      value when value in ["scanned", "scan_failed", "not_scanned", "unchanged"] -> value
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

      "unchanged" ->
        datetime_value(payload, :last_successful_scan_at) ||
          datetime_value(payload, :last_scan_at) ||
          fallback

      _ ->
        datetime_value(payload, :last_successful_scan_at)
    end
  end

  defp inferred_upload_reason(payload) do
    if map_size(map_value(payload, :sbom)) > 0 or list_value(payload, :packages) != [] do
      @upload_reason_changed
    else
      @upload_reason_unchanged
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

  defp candidate_cpes(cpes, name, version) do
    supplied = normalize_cpes(cpes)

    derived =
      name
      |> known_cpe_products()
      |> Enum.map(fn {vendor, product} ->
        build_cpe23(vendor, product, version)
      end)

    normalize_cpes(supplied ++ derived)
  end

  defp known_cpe_products(name) do
    normalized = normalize_token(name)

    Map.get(@known_cpe_products, normalized, [])
  end

  defp build_cpe23(vendor, product, version) do
    "cpe:2.3:a:#{cpe23_part(vendor)}:#{cpe23_part(product)}:#{cpe23_part(version || "*")}:*:*:*:*:*:*:*"
  end

  defp normalize_cpes(cpes) do
    cpes
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cpe23_part(nil), do: "*"

  defp cpe23_part(value) do
    case value |> to_string() |> String.trim() do
      "" ->
        "*"

      part ->
        part
        |> String.downcase()
        |> String.replace("\\", "\\\\")
        |> String.replace(":", "\\:")
        |> String.replace("*", "\\*")
        |> String.replace("?", "\\?")
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

  defp number_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        parse_float(value)

      _ ->
        nil
    end
  end

  defp number_value(_map, _key), do: nil

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {float, _rest} -> float
      :error -> nil
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

  defp trimmed(nil), do: ""

  defp trimmed(value) when is_binary(value), do: String.trim(value)

  defp trimmed(value), do: value |> to_string() |> String.trim()

  defp trimmed_or_nil(value) do
    case trimmed(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp json_string(value), do: Jason.encode!(value)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
