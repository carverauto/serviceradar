defmodule ServiceRadar.Inventory.BumblebeeCatalogRefreshEventWriter do
  @moduledoc """
  Records Bumblebee catalog refresh lifecycle events into OCSF event storage.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.BumblebeeCatalogSource
  alias ServiceRadar.Monitoring
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @event_family "bumblebee_catalog_refresh"
  @log_name "bumblebee.catalog.refresh"
  @log_provider "serviceradar.core"
  @process_name "bumblebee_catalog_refresh"

  @spec write_success(BumblebeeCatalogSource.t(), BumblebeeCatalogSnapshot.t(), keyword()) ::
          :ok | {:error, term()}
  def write_success(
        %BumblebeeCatalogSource{} = source,
        %BumblebeeCatalogSnapshot{} = snapshot,
        opts \\ []
      ) do
    actor =
      Keyword.get(opts, :actor) || SystemActor.system(:bumblebee_catalog_refresh_event_writer)

    source
    |> build_success_attrs(snapshot)
    |> record_event(actor)
  end

  @spec write_failure(BumblebeeCatalogSource.t(), term(), keyword()) :: :ok | {:error, term()}
  def write_failure(%BumblebeeCatalogSource{} = source, reason, opts \\ []) do
    actor =
      Keyword.get(opts, :actor) || SystemActor.system(:bumblebee_catalog_refresh_event_writer)

    source
    |> build_failure_attrs(reason)
    |> record_event(actor)
  end

  defp build_success_attrs(source, snapshot) do
    build_attrs(source,
      status_id: OCSF.status_success(),
      severity_id: OCSF.severity_informational(),
      status_code: "bumblebee_catalog_refresh_success",
      status_detail: nil,
      message: "Bumblebee catalog source #{source.name} refreshed successfully",
      log_level: "info",
      event_action: "success",
      snapshot: snapshot
    )
  end

  defp build_failure_attrs(source, reason) do
    reason = reason_summary(reason)

    build_attrs(source,
      status_id: OCSF.status_failure(),
      severity_id: OCSF.severity_medium(),
      status_code: "bumblebee_catalog_refresh_failure",
      status_detail: reason,
      message: "Bumblebee catalog source #{source.name} refresh failed: #{reason}",
      log_level: "warning",
      event_action: "failure",
      reason: reason
    )
  end

  defp build_attrs(source, opts) do
    activity_id = OCSF.activity_log_update()
    status_id = Keyword.fetch!(opts, :status_id)
    severity_id = Keyword.fetch!(opts, :severity_id)
    snapshot = Keyword.get(opts, :snapshot)
    event_action = Keyword.fetch!(opts, :event_action)

    %{
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      status_code: Keyword.fetch!(opts, :status_code),
      status_detail: Keyword.get(opts, :status_detail),
      message: Keyword.fetch!(opts, :message),
      metadata:
        [
          product_name: "ServiceRadar Core",
          correlation_uid: source_correlation_uid(source)
        ]
        |> OCSF.build_metadata()
        |> Map.put(:event_family, @event_family)
        |> Map.put(:event_action, event_action),
      observables: build_observables(source, snapshot),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: @process_name),
      log_name: @log_name,
      log_provider: @log_provider,
      log_level: Keyword.fetch!(opts, :log_level),
      unmapped: build_unmapped(source, snapshot, opts)
    }
  end

  defp record_event(attrs, actor) do
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create(domain: Monitoring)
    |> case do
      {:ok, event} ->
        ServiceRadar.Events.PubSub.broadcast_event(event)
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to record Bumblebee catalog refresh event",
          reason: inspect(reason)
        )

        error
    end
  rescue
    exception ->
      Logger.warning("Failed to record Bumblebee catalog refresh event",
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, exception}
  end

  defp build_observables(source, snapshot) do
    Enum.reject(
      [
        observable(source.id, "Bumblebee Catalog Source ID"),
        observable(source.name, "Bumblebee Catalog Source Name"),
        observable(snapshot && snapshot.snapshot_ref, "Bumblebee Catalog Snapshot Ref")
      ],
      &is_nil/1
    )
  end

  defp observable(nil, _type), do: nil
  defp observable(value, type), do: OCSF.build_observable(to_string(value), type, 99)

  defp build_unmapped(source, snapshot, opts) do
    %{
      "event_family" => @event_family,
      "event_action" => Keyword.fetch!(opts, :event_action),
      "source_id" => to_string(source.id),
      "source_name" => source.name,
      "source_url" => sanitized_url(source.url),
      "source_enabled" => source.enabled,
      "status" => OCSF.status_name(Keyword.fetch!(opts, :status_id)),
      "status_code" => Keyword.fetch!(opts, :status_code),
      "reason" => Keyword.get(opts, :reason)
    }
    |> maybe_put_snapshot(snapshot)
    |> compact_map()
  end

  defp maybe_put_snapshot(map, nil), do: map

  defp maybe_put_snapshot(map, %BumblebeeCatalogSnapshot{} = snapshot) do
    Map.merge(map, %{
      "snapshot_id" => to_string(snapshot.id),
      "snapshot_ref" => snapshot.snapshot_ref,
      "catalog_version" => snapshot.catalog_version,
      "source_revision" => snapshot.source_revision,
      "entry_count" => snapshot.entry_count,
      "content_sha256" => snapshot.content_sha256,
      "object_key" => snapshot.object_key,
      "object_size_bytes" => snapshot.object_size_bytes
    })
  end

  defp source_correlation_uid(%BumblebeeCatalogSource{id: id}) when not is_nil(id) do
    "bumblebee_catalog_source:#{id}"
  end

  defp source_correlation_uid(%BumblebeeCatalogSource{name: name}),
    do: "bumblebee_catalog_source:#{name}"

  defp reason_summary(%_{} = reason) do
    Exception.message(reason)
  rescue
    _ -> inspect(reason, limit: 20, printable_limit: 500)
  end

  defp reason_summary(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 1_000)
  end

  defp sanitized_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp sanitized_url(_url), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
