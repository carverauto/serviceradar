defmodule ServiceRadar.Integrations.ArmisNorthboundRunner do
  @moduledoc """
  Helper logic for Armis northbound availability updates.

  This module currently focuses on the deterministic, testable pieces of the
  northbound flow:
  - validating whether a source can run northbound updates
  - loading persisted Armis candidates from canonical inventory state
  - collapsing candidate device rows to one record per `armis_device_id`
  - batching outbound updates for bulk API submission
  - building the bulk payload written to the configured custom field
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Monitoring
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Repo

  require Logger

  @default_batch_size 500
  @stale_run_cutoff_seconds 120
  @northbound_log_name "integrations.armis.northbound"

  @type candidate :: %{
          required(:armis_device_id) => String.t(),
          required(:is_available) => boolean(),
          optional(:device_id) => String.t(),
          optional(:sync_service_id) => String.t(),
          optional(:metadata) => map()
        }

  @type collapsed_candidate :: %{
          armis_device_id: String.t(),
          is_available: boolean(),
          device_ids: [String.t()],
          sync_service_ids: [String.t()],
          metadata: map()
        }

  @spec northbound_ready?(struct() | map(), keyword()) :: :ok | {:error, atom()}
  def northbound_ready?(source, opts \\ []) do
    cond do
      not Keyword.get(opts, :manual?, false) and not Map.get(source, :northbound_enabled, false) ->
        {:error, :northbound_disabled}

      is_nil(custom_field(source)) ->
        {:error, :missing_custom_field}

      blank?(Map.get(source, :endpoint)) ->
        {:error, :missing_endpoint}

      credentials(source) == %{} ->
        {:error, :missing_credentials}

      true ->
        :ok
    end
  end

  @spec custom_field(struct() | map()) :: String.t() | nil
  def custom_field(source) do
    source
    |> Map.get(:custom_fields, [])
    |> case do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @spec credentials(struct() | map()) :: map()
  def credentials(source) do
    source
    |> Map.get(:credentials, %{})
    |> case do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  @spec batch_size(struct() | map(), pos_integer()) :: pos_integer()
  def batch_size(source, default \\ @default_batch_size) do
    source
    |> Map.get(:settings, %{})
    |> extract_batch_size(default)
  end

  @spec load_candidates(IntegrationSource.t() | map(), keyword()) ::
          {:ok, [candidate()]} | {:error, atom()}
  def load_candidates(source, opts \\ []) do
    with :ok <- northbound_ready?(source, opts) do
      {:ok, Repo.all(candidates_query(source))}
    end
  end

  @spec run_for_source(IntegrationSource.t() | map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def run_for_source(source, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:armis_northbound_runner))
    start_run = Keyword.get(opts, :start_run, &default_start_run/3)
    update_source = Keyword.get(opts, :update_source, &default_update_source/4)
    finish_run = Keyword.get(opts, :finish_run, &default_finish_run/5)
    record_event = Keyword.get(opts, :record_event, &default_record_event/2)
    load_candidates_fun = Keyword.get(opts, :load_candidates, &load_candidates/2)
    execute_batches_fun = Keyword.get(opts, :execute_batches, &execute_batches/3)

    with {:ok, run} <- start_run.(source, actor, opts),
         {:ok, candidates} <- load_candidates_fun.(source, opts),
         collapsed = collapse_candidates(candidates),
         {:ok, _source} <-
           update_source.(source, :northbound_start, %{device_count: length(collapsed)}, actor) do
      case execute_batches_fun.(source, collapsed, opts) do
        {:ok, result} ->
          finalize_success(source, run, result, actor, finish_run, update_source, record_event)

        {:error, result} when is_map(result) ->
          finalize_error(source, run, result, actor, finish_run, update_source, record_event)

        {:error, reason} ->
          result = %{
            device_count: length(collapsed),
            updated_count: 0,
            skipped_count: 0,
            error_count: length(collapsed),
            batch_count: 0,
            errors: [%{reason: reason}]
          }

          finalize_error(source, run, result, actor, finish_run, update_source, record_event)
      end
    end
  end

  @spec execute_batches(IntegrationSource.t() | map(), [collapsed_candidate()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def execute_batches(source, candidates, opts \\ []) do
    with :ok <- northbound_ready?(source, opts),
         {:ok, token} <- fetch_access_token(source, opts) do
      request = Keyword.get(opts, :request, &default_request/5)
      custom_field = custom_field(source)
      batches = batch_candidates(candidates, batch_size(source))

      initial = %{
        device_count: length(candidates),
        updated_count: 0,
        skipped_count: 0,
        error_count: 0,
        batch_count: length(batches),
        errors: []
      }

      result =
        Enum.reduce_while(batches, initial, fn batch, acc ->
          payload = build_bulk_payload(custom_field, batch)

          case request.(
                 "/api/v1/devices/custom-properties/_bulk/",
                 :post,
                 request_headers(token),
                 payload,
                 request_options(source)
               ) do
            {:ok, %{status: status}} when status in 200..299 ->
              {:cont, %{acc | updated_count: acc.updated_count + length(batch)}}

            {:ok, %{status: status, body: body}} ->
              error = %{batch_size: length(batch), reason: {:unexpected_status, status, body}}

              {:halt,
               %{
                 acc
                 | error_count: acc.error_count + length(batch),
                   errors: acc.errors ++ [error]
               }}

            {:error, reason} ->
              error = %{batch_size: length(batch), reason: reason}

              {:halt,
               %{
                 acc
                 | error_count: acc.error_count + length(batch),
                   errors: acc.errors ++ [error]
               }}
          end
        end)

      if result.errors == [] do
        {:ok, result}
      else
        {:error, result}
      end
    end
  end

  @spec candidates_query(IntegrationSource.t() | map()) :: Ecto.Query.t()
  def candidates_query(source) do
    source_id = to_string(Map.fetch!(source, :id))

    from(di in DeviceIdentifier,
      join: d in Device,
      on: d.uid == di.device_id,
      where: di.identifier_type == :armis_device_id,
      where: not is_nil(d.uid) and is_nil(d.deleted_at),
      where:
        fragment(
          "COALESCE(?->>'sync_service_id', ?->>'sync_service_id', '') = ?",
          di.metadata,
          d.metadata,
          ^source_id
        ),
      where:
        fragment(
          "COALESCE(?->>'integration_type', ?->>'integration_type', '') = 'armis'",
          di.metadata,
          d.metadata
        ),
      select: %{
        armis_device_id: di.identifier_value,
        is_available: fragment("COALESCE(?, false)", d.is_available),
        device_id: d.uid,
        sync_service_id:
          fragment(
            "COALESCE(?->>'sync_service_id', ?->>'sync_service_id')",
            di.metadata,
            d.metadata
          ),
        metadata:
          fragment(
            "jsonb_strip_nulls(COALESCE(?, '{}'::jsonb) || jsonb_build_object('integration_type', COALESCE(?->>'integration_type', ?->>'integration_type')))::jsonb",
            d.metadata,
            di.metadata,
            d.metadata
          )
      },
      order_by: [asc: di.identifier_value, asc: d.uid]
    )
  end

  @spec collapse_candidates([candidate()]) :: [collapsed_candidate()]
  def collapse_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      armis_device_id = Map.fetch!(candidate, :armis_device_id)
      availability = Map.fetch!(candidate, :is_available)
      device_id = Map.get(candidate, :device_id)
      sync_service_id = Map.get(candidate, :sync_service_id)
      metadata = Map.get(candidate, :metadata, %{})

      Map.update(
        acc,
        armis_device_id,
        %{
          armis_device_id: armis_device_id,
          is_available: availability,
          device_ids: compact_unique([device_id]),
          sync_service_ids: compact_unique([sync_service_id]),
          metadata: metadata
        },
        fn existing ->
          %{
            existing
            | is_available: existing.is_available and availability,
              device_ids: compact_unique(existing.device_ids ++ [device_id]),
              sync_service_ids: compact_unique(existing.sync_service_ids ++ [sync_service_id]),
              metadata: Map.merge(existing.metadata, metadata)
          }
        end
      )
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.armis_device_id)
  end

  @spec batch_candidates([collapsed_candidate()], pos_integer()) :: [[collapsed_candidate()]]
  def batch_candidates(candidates, batch_size \\ @default_batch_size) when batch_size > 0 do
    Enum.chunk_every(candidates, batch_size)
  end

  @spec build_bulk_payload(String.t(), [collapsed_candidate()]) :: [map()]
  def build_bulk_payload(custom_field, candidates)
      when is_binary(custom_field) and custom_field != "" do
    Enum.map(candidates, fn candidate ->
      %{
        "id" => candidate.armis_device_id,
        "customProperties" => %{
          custom_field => candidate.is_available
        }
      }
    end)
  end

  defp compact_unique(values) do
    values
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp finalize_success(source, run, result, actor, finish_run, update_source, record_event) do
    metadata = %{batch_count: result.batch_count, errors: serialize_errors(result.errors)}

    with {:ok, finished_run} <-
           finish_run.(
             run,
             :finish_success,
             build_run_attrs(result, metadata),
             actor,
             %{status: :success}
           ),
         {:ok, updated_source} <-
           update_source.(
             source,
             :northbound_success,
             build_source_success_attrs(result, :success),
             actor
           ) do
      maybe_record_run_event(updated_source, finished_run, result, actor, :success, record_event)
      {:ok, %{run: finished_run, source: updated_source, result: result}}
    end
  end

  defp finalize_error(source, run, result, actor, finish_run, update_source, record_event) do
    metadata = %{batch_count: result.batch_count, errors: serialize_errors(result.errors)}
    error_message = summarize_errors(result.errors)

    if result.updated_count > 0 do
      with {:ok, finished_run} <-
             finish_run.(
               run,
               :finish_partial,
               build_run_attrs(result, Map.put(metadata, :error_message, error_message)),
               actor,
               %{status: :partial}
             ),
           {:ok, updated_source} <-
             update_source.(
               source,
               :northbound_success,
               build_source_success_attrs(result, :partial),
               actor
             ) do
        maybe_record_run_event(
          updated_source,
          finished_run,
          Map.put(result, :error_message, error_message),
          actor,
          :partial,
          record_event
        )

        {:error,
         %{
           run: finished_run,
           source: updated_source,
           result: Map.put(result, :error_message, error_message)
         }}
      end
    else
      with {:ok, finished_run} <-
             finish_run.(
               run,
               :finish_failed,
               build_run_attrs(result, Map.put(metadata, :error_message, error_message)),
               actor,
               %{status: :failed}
             ),
           {:ok, updated_source} <-
             update_source.(
               source,
               :northbound_failed,
               build_source_failed_attrs(result, error_message),
               actor
             ) do
        maybe_record_run_event(
          updated_source,
          finished_run,
          Map.put(result, :error_message, error_message),
          actor,
          :failed,
          record_event
        )

        {:error,
         %{
           run: finished_run,
           source: updated_source,
           result: Map.put(result, :error_message, error_message)
         }}
      end
    end
  end

  defp build_run_attrs(result, metadata) do
    %{
      device_count: result.device_count,
      updated_count: result.updated_count,
      skipped_count: result.skipped_count,
      error_count: result.error_count,
      error_message: Map.get(metadata, :error_message),
      metadata: metadata
    }
  end

  defp build_source_success_attrs(result, status) do
    %{
      result: status,
      device_count: result.device_count,
      updated_count: result.updated_count,
      skipped_count: result.skipped_count + result.error_count
    }
  end

  defp build_source_failed_attrs(result, error_message) do
    %{
      result: :failed,
      device_count: result.device_count,
      updated_count: result.updated_count,
      skipped_count: result.skipped_count + result.error_count,
      error_message: error_message
    }
  end

  defp summarize_errors([]), do: nil

  defp summarize_errors(errors) do
    Enum.map_join(errors, "; ", fn error -> inspect(error.reason) end)
  end

  defp serialize_errors(errors) when is_list(errors) do
    Enum.map(errors, &serialize_error/1)
  end

  defp serialize_errors(_), do: []

  defp serialize_error(%{reason: reason} = error) do
    base = if Map.has_key?(error, :__struct__), do: Map.from_struct(error), else: error
    Map.put(base, :reason, inspect(reason))
  end

  defp serialize_error(error), do: %{reason: inspect(error)}

  defp maybe_record_run_event(source, run, result, actor, status, record_event) do
    attrs = build_run_event_attrs(source, run, result, status)

    case record_event.(attrs, actor) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record Armis northbound run event",
          integration_source_id: inspect(Map.get(source, :id)),
          run_id: inspect(Map.get(run, :id)),
          status: status,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp build_run_event_attrs(source, run, result, status) do
    severity_id = event_severity_id(status)
    status_id = event_status_id(status)
    activity_id = OCSF.activity_log_update()

    metadata =
      maybe_put_string(
        %{
          "integration_source_id" => Map.get(source, :id),
          "integration_source_name" => Map.get(source, :name),
          "integration_type" => "armis",
          "run_id" => Map.get(run, :id),
          "run_type" => "armis_northbound",
          "device_count" => result.device_count,
          "updated_count" => result.updated_count,
          "skipped_count" => result.skipped_count,
          "error_count" => result.error_count,
          "batch_count" => result.batch_count,
          "custom_field" => custom_field(source)
        },
        "error_message",
        Map.get(result, :error_message)
      )

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
      status_code: event_status_code(status),
      status_detail: event_status_detail(status),
      message: build_run_event_message(source, result, status),
      metadata: OCSF.build_metadata(product_name: "Armis Northbound Runner"),
      observables: build_run_event_observables(source, run),
      log_name: @northbound_log_name,
      log_provider: "serviceradar_core",
      log_level: event_log_level(status),
      raw_data: Jason.encode!(metadata)
    }
  end

  defp build_run_event_message(source, result, status) do
    source_name = Map.get(source, :name, "armis")

    base =
      "Armis northbound run for #{source_name} finished with #{status}: " <>
        "#{result.updated_count}/#{result.device_count} devices updated"

    if blank?(Map.get(result, :error_message)) do
      base
    else
      base <> " (#{result.error_message})"
    end
  end

  defp build_run_event_observables(source, run) do
    Enum.reject(
      [
        observable(Map.get(source, :id), "Integration Source ID"),
        observable(Map.get(source, :name), "Integration Source"),
        observable(Map.get(run, :id), "Northbound Run ID"),
        observable(custom_field(source), "Armis Custom Field")
      ],
      &is_nil/1
    )
  end

  defp default_record_event(attrs, actor) do
    Ash.create(OcsfEvent, attrs,
      action: :record,
      actor: actor,
      domain: Monitoring
    )
  end

  defp event_severity_id(:success), do: OCSF.severity_informational()
  defp event_severity_id(:partial), do: OCSF.severity_medium()
  defp event_severity_id(:failed), do: OCSF.severity_high()

  defp event_status_id(:success), do: OCSF.status_success()
  defp event_status_id(:partial), do: OCSF.status_other()
  defp event_status_id(:failed), do: OCSF.status_failure()

  defp event_status_code(:success), do: "armis_northbound_bulk_update_succeeded"
  defp event_status_code(:partial), do: "armis_northbound_bulk_update_partial"
  defp event_status_code(:failed), do: "armis_northbound_bulk_update_failed"

  defp event_status_detail(:success), do: "All Armis northbound bulk updates succeeded"
  defp event_status_detail(:partial), do: "Some Armis northbound bulk updates failed"
  defp event_status_detail(:failed), do: "Armis northbound bulk update run failed"

  defp event_log_level(:success), do: "info"
  defp event_log_level(:partial), do: "warning"
  defp event_log_level(:failed), do: "error"

  defp observable(nil, _name), do: nil
  defp observable("", _name), do: nil

  defp observable(value, name) do
    %{"name" => name, "type" => "string", "value" => to_string(value)}
  end

  defp maybe_put_string(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp default_start_run(source, actor, opts) do
    oban_job_id = Keyword.get(opts, :oban_job_id)
    :ok = reconcile_stale_runs(source, actor, opts)

    IntegrationUpdateRun
    |> Ash.Changeset.for_create(
      :start_run,
      %{
        integration_source_id: Map.fetch!(source, :id),
        run_type: :armis_northbound,
        oban_job_id: oban_job_id,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  def reconcile_stale_runs(source, actor, opts) do
    list_runs = Keyword.get(opts, :list_runs, &list_recent_runs/2)
    finish_run = Keyword.get(opts, :finish_run, &default_finish_run/5)
    oban_state = Keyword.get(opts, :oban_state, &fetch_oban_job_state/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff_seconds = Keyword.get(opts, :stale_run_cutoff_seconds, @stale_run_cutoff_seconds)

    source
    |> list_runs.(actor)
    |> Enum.filter(&stale_running_run?(&1, now, cutoff_seconds))
    |> Enum.each(fn run ->
      if orphaned_oban_state?(oban_state.(run.oban_job_id)) do
        attrs = %{
          device_count: run.device_count || 0,
          updated_count: run.updated_count || 0,
          skipped_count: run.skipped_count || 0,
          error_count: run.error_count || 0,
          error_message: "Marked timed out after orphaned Oban job",
          metadata:
            Map.merge(run.metadata || %{}, %{
              "reconciled" => true,
              "reason" => "orphaned_oban_job"
            })
        }

        case finish_run.(run, :finish_timeout, attrs, actor, %{status: :timeout}) do
          {:ok, _finished_run} -> :ok
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp list_recent_runs(source, actor) do
    IntegrationUpdateRun
    |> Ash.Query.for_read(:recent_by_source, %{integration_source_id: Map.fetch!(source, :id)},
      actor: actor
    )
    |> Ash.read!(actor: actor)
  end

  defp stale_running_run?(run, now, cutoff_seconds) do
    run.status == :running and
      is_struct(run.started_at, DateTime) and
      DateTime.diff(now, run.started_at, :second) >= cutoff_seconds
  end

  defp orphaned_oban_state?(nil), do: true
  defp orphaned_oban_state?(state) when state in ["completed", "discarded", "cancelled"], do: true
  defp orphaned_oban_state?(_state), do: false

  defp fetch_oban_job_state(nil), do: nil

  defp fetch_oban_job_state(oban_job_id) do
    case Repo.query("select state::text from platform.oban_jobs where id = $1 limit 1", [
           oban_job_id
         ]) do
      {:ok, %{rows: [[state]]}} -> state
      _ -> nil
    end
  end

  defp default_update_source(source, action, attrs, actor) do
    source
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp default_finish_run(run, action, attrs, actor, _opts) do
    run
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp fetch_access_token(source, opts) do
    fetcher = Keyword.get(opts, :token_fetcher, &default_token_fetcher/1)
    fetcher.(source)
  end

  defp default_token_fetcher(source) do
    credentials = credentials(source)
    api_key = Map.get(credentials, "api_key") || Map.get(credentials, :api_key)
    api_secret = Map.get(credentials, "api_secret") || Map.get(credentials, :api_secret)

    body = %{}
    body = if blank?(api_key), do: body, else: Map.put(body, "api_key", api_key)
    body = if blank?(api_secret), do: body, else: Map.put(body, "api_secret", api_secret)

    case default_request(
           "/api/v1/access_token/",
           :post,
           %{"content-type" => "application/json"},
           body,
           request_options(source)
         ) do
      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) ->
        {:error, :missing_access_token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_request_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers(token) do
    %{
      "authorization" => "Bearer #{token}",
      "content-type" => "application/json",
      "accept" => "application/json"
    }
  end

  defp request_options(source) do
    [base_url: Map.fetch!(source, :endpoint)]
  end

  defp default_request(path, method, headers, body, opts) do
    request =
      [method: method, url: path, json: body, headers: Enum.to_list(headers)]
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_batch_size(settings, default) when is_map(settings) do
    case Map.get(settings, "batch_size") || Map.get(settings, :batch_size) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_int(value, default)
      _ -> default
    end
  end

  defp extract_batch_size(_, default), do: default

  defp parse_positive_int(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
