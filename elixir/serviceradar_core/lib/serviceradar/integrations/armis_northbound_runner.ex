defmodule ServiceRadar.Integrations.ArmisNorthboundRunner do
  @moduledoc """
  Helper logic for Armis northbound availability updates.

  This module currently focuses on the deterministic, testable pieces of the
  northbound flow:
  - validating whether a source can run northbound updates
  - loading persisted Armis candidates from canonical inventory state
  - collapsing candidate device rows to one record per integration ID
  - batching outbound updates for bulk API submission
  - building the bulk payload written to the configured custom field
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Integrations.ArmisNorthboundLedger
  alias ServiceRadar.Integrations.ArmisNorthboundPopulation
  alias ServiceRadar.Integrations.CompositeNorthboundValues
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
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

  @typedoc """
  An operator's selection of a composite check to export alongside availability.
  """
  @type composite_export :: %{
          check_slug: String.t(),
          value_form: :verdict | :status,
          custom_field: String.t()
        }

  @doc """
  The composite check export configured on this source, or nil.

  Lives in `settings` rather than as a second `custom_fields` entry: the
  selection is three coupled values, and a positional entry would silently
  become the composite field for any source that happens to configure two.

  All three values are required. A half-configured export reads as "not
  configured" rather than partially applying — there is no useful behaviour for
  "a check and a value form but nowhere to write them".
  """
  @spec composite_export(struct() | map()) :: composite_export() | nil
  def composite_export(source) do
    source
    |> Map.get(:settings, %{})
    |> case do
      settings when is_map(settings) -> Map.get(settings, "composite")
      _other -> nil
    end
    |> build_composite_export()
  end

  defp build_composite_export(config) when is_map(config) do
    with slug when is_binary(slug) <- present(config, "check_slug"),
         field when is_binary(field) <- present(config, "custom_field"),
         form when form in [:verdict, :status] <- value_form(config) do
      %{check_slug: slug, value_form: form, custom_field: field}
    else
      _incomplete -> nil
    end
  end

  defp build_composite_export(_config), do: nil

  # An unrecognised form disables the export. Guessing would publish the wrong
  # vocabulary to a downstream system, which is worse than publishing nothing.
  defp value_form(config) do
    case present(config, "value_form") do
      "verdict" -> :verdict
      "status" -> :status
      _other -> nil
    end
  end

  defp present(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  @spec credentials(struct() | map()) :: map()
  def credentials(source) do
    source
    |> Map.get(:credentials, %{})
    |> case do
      %Ash.NotLoaded{} -> %{}
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
    with :ok <- northbound_ready?(source, opts),
         :ok <- availability_source_ready?(source) do
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

    load_population_fun =
      Keyword.get_lazy(opts, :load_population, fn ->
        if Keyword.has_key?(opts, :load_candidates) do
          legacy_population_loader(load_candidates_fun)
        else
          &ArmisNorthboundPopulation.load/2
        end
      end)

    load_identity_conflicts_fun =
      Keyword.get(
        opts,
        :load_identity_conflicts,
        default_identity_conflict_loader(opts)
      )

    execute_batches_fun = Keyword.get(opts, :execute_batches, &execute_batches/3)

    case start_run.(source, actor, opts) do
      {:ok, run} ->
        run_started_for_source(
          source,
          run,
          actor,
          opts,
          update_source,
          finish_run,
          record_event,
          load_population_fun,
          load_identity_conflicts_fun,
          execute_batches_fun
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp run_started_for_source(
         source,
         run,
         actor,
         opts,
         update_source,
         finish_run,
         record_event,
         load_population_fun,
         load_identity_conflicts_fun,
         execute_batches_fun
       ) do
    Logger.info("Starting Armis northbound run",
      integration_source_id: inspect(Map.get(source, :id)),
      run_id: inspect(Map.get(run, :id))
    )

    load_result =
      with :ok <- northbound_ready?(source, opts) do
        load_population_fun.(source, opts)
      end

    case load_result do
      {:ok, population} ->
        identity_conflicts = load_identity_conflicts_fun.(source, opts)
        collapsed = collapse_candidates(population.candidates)
        population = complete_population(population, collapsed, identity_conflicts)
        device_count = population.distinct_source_ids

        Logger.info("Loaded Armis northbound candidates",
          integration_source_id: inspect(Map.get(source, :id)),
          run_id: inspect(Map.get(run, :id)),
          device_count: device_count,
          outbound_device_count: length(collapsed),
          withheld_count: population.withheld_count,
          identity_conflict_total: SourceIdentityDrift.conflict_count(identity_conflicts)
        )

        case ArmisNorthboundLedger.bind(run, population, actor) do
          {:ok, bound_run} ->
            start_bound_run(
              source,
              bound_run,
              collapsed,
              population,
              actor,
              opts,
              finish_run,
              update_source,
              record_event,
              identity_conflicts,
              execute_batches_fun
            )

          {:error, reason} ->
            fail_started_run(
              source,
              run,
              failure_result(device_count, reason),
              actor,
              finish_run,
              update_source,
              record_event
            )
        end

      {:error, reason} ->
        fail_started_run(
          source,
          run,
          failure_result(0, reason),
          actor,
          finish_run,
          update_source,
          record_event
        )
    end
  rescue
    exception ->
      fail_started_run(
        source,
        run,
        failure_result(0, {exception.__struct__, Exception.message(exception)}),
        actor,
        finish_run,
        update_source,
        record_event
      )
  end

  defp start_bound_run(
         source,
         run,
         collapsed,
         population,
         actor,
         opts,
         finish_run,
         update_source,
         record_event,
         identity_conflicts,
         execute_batches_fun
       ) do
    case update_source.(
           source,
           :northbound_start,
           %{device_count: population.distinct_source_ids},
           actor
         ) do
      {:ok, _source} ->
        execute_started_run(
          source,
          run,
          collapsed,
          population,
          actor,
          opts,
          finish_run,
          update_source,
          record_event,
          identity_conflicts,
          execute_batches_fun
        )

      {:error, reason} ->
        fail_bound_run(
          source,
          run,
          collapsed,
          population,
          identity_conflicts,
          reason,
          actor,
          finish_run,
          update_source,
          record_event
        )
    end
  rescue
    exception ->
      fail_bound_run(
        source,
        run,
        collapsed,
        population,
        identity_conflicts,
        {exception.__struct__, Exception.message(exception)},
        actor,
        finish_run,
        update_source,
        record_event
      )
  end

  defp execute_started_run(
         source,
         run,
         collapsed,
         population,
         actor,
         opts,
         finish_run,
         update_source,
         record_event,
         identity_conflicts,
         execute_batches_fun
       ) do
    case execute_batches_fun.(source, collapsed, opts) do
      {:ok, result} ->
        result = prepare_result(result, population, collapsed, identity_conflicts)

        case ArmisNorthboundLedger.finalize(run, population, result) do
          {:ok, result} ->
            finalize_success(source, run, result, actor, finish_run, update_source, record_event)

          {:error, reason} ->
            result = ledger_failure_result(result, reason)
            finalize_error(source, run, result, actor, finish_run, update_source, record_event)
        end

      {:error, result} when is_map(result) ->
        result = prepare_result(result, population, collapsed, identity_conflicts)

        case ArmisNorthboundLedger.finalize(run, population, result) do
          {:ok, result} ->
            finalize_error(source, run, result, actor, finish_run, update_source, record_event)

          {:error, reason} ->
            result = ledger_failure_result(result, reason)
            finalize_error(source, run, result, actor, finish_run, update_source, record_event)
        end

      {:error, reason} ->
        result =
          prepare_result(
            %{
              device_count: length(collapsed),
              updated_count: 0,
              skipped_count: 0,
              error_count: length(collapsed),
              batch_count: 0,
              errors: [%{reason: reason}],
              accepted_ids: [],
              failed_ids: [],
              unattempted_ids: candidate_ids(collapsed)
            },
            population,
            collapsed,
            identity_conflicts
          )

        case ArmisNorthboundLedger.finalize(run, population, result) do
          {:ok, result} ->
            finalize_error(source, run, result, actor, finish_run, update_source, record_event)

          {:error, ledger_reason} ->
            result = ledger_failure_result(result, ledger_reason)
            finalize_error(source, run, result, actor, finish_run, update_source, record_event)
        end
    end
  rescue
    exception ->
      fail_bound_run(
        source,
        run,
        collapsed,
        population,
        identity_conflicts,
        {exception.__struct__, Exception.message(exception)},
        actor,
        finish_run,
        update_source,
        record_event
      )
  end

  defp legacy_population_loader(load_candidates_fun) do
    fn source, opts ->
      with {:ok, candidates} <- load_candidates_fun.(source, opts) do
        {:ok, %{accounted?: false, candidates: candidates}}
      end
    end
  end

  defp complete_population(%{accounted?: true} = population, _collapsed, _conflicts),
    do: population

  defp complete_population(population, collapsed, identity_conflicts) do
    withheld = SourceIdentityDrift.withheld_conflict_count(identity_conflicts)

    population
    |> Map.put(:distinct_source_ids, length(collapsed) + withheld)
    |> Map.put(:eligible_count, length(collapsed))
    |> Map.put(:withheld_count, withheld)
  end

  defp prepare_result(result, population, collapsed, identity_conflicts) do
    result
    |> ensure_outcome_ids(collapsed)
    |> attach_population(population)
    |> attach_identity_conflicts(identity_conflicts)
  end

  defp ensure_outcome_ids(result, collapsed) do
    if Enum.all?([:accepted_ids, :failed_ids, :unattempted_ids], &Map.has_key?(result, &1)) do
      result
    else
      ids = candidate_ids(collapsed)

      cond do
        Map.get(result, :errors, []) == [] and Map.get(result, :updated_count, 0) == length(ids) ->
          Map.merge(result, %{accepted_ids: ids, failed_ids: [], unattempted_ids: []})

        Map.get(result, :updated_count, 0) == 0 ->
          Map.merge(result, %{accepted_ids: [], failed_ids: [], unattempted_ids: ids})

        true ->
          result
      end
    end
  end

  defp attach_population(result, %{accounted?: true} = population) do
    accepted_count = result |> Map.get(:accepted_ids, []) |> length()
    failed_count = result |> Map.get(:failed_ids, []) |> length()
    unattempted_count = result |> Map.get(:unattempted_ids, []) |> length()

    result
    |> Map.put(:device_count, population.distinct_source_ids)
    |> Map.put(:eligible_count, population.eligible_count)
    |> Map.put(:withheld_count, population.withheld_count)
    |> Map.put(:accepted_count, accepted_count)
    |> Map.put(:failed_count, failed_count)
    |> Map.put(:unattempted_count, unattempted_count)
    |> Map.put(:updated_count, accepted_count)
    |> Map.put(:skipped_count, population.withheld_count)
    |> Map.put(:error_count, failed_count + unattempted_count)
    |> Map.put(:collection, population.accounting)
    |> Map.put(:withheld_reason_counts, population.reason_counts)
  end

  defp attach_population(result, %{accounted?: false} = population) do
    result
    |> Map.put(:device_count, population.distinct_source_ids)
    |> Map.put(:skipped_count, population.withheld_count)
    |> Map.put(:identity_withholding_included, true)
  end

  defp attach_population(result, _population), do: result

  defp ledger_failure_result(result, reason) do
    result
    |> Map.update(:errors, [%{reason: reason}], &(&1 ++ [%{reason: reason}]))
    |> Map.put(:reconciliation_status, :failed)
  end

  defp fail_started_run(source, run, result, actor, finish_run, update_source, record_event) do
    Logger.warning("Armis northbound run failed before completion",
      integration_source_id: inspect(Map.get(source, :id)),
      run_id: inspect(Map.get(run, :id)),
      reason: summarize_errors(result.errors)
    )

    finalize_error(source, run, result, actor, finish_run, update_source, record_event)
  end

  defp fail_bound_run(
         source,
         run,
         collapsed,
         population,
         identity_conflicts,
         reason,
         actor,
         finish_run,
         update_source,
         record_event
       ) do
    result =
      prepare_result(
        %{
          device_count: length(collapsed),
          updated_count: 0,
          skipped_count: 0,
          error_count: length(collapsed),
          batch_count: 0,
          errors: [%{reason: reason}],
          accepted_ids: [],
          failed_ids: [],
          unattempted_ids: candidate_ids(collapsed)
        },
        population,
        collapsed,
        identity_conflicts
      )

    result =
      case ArmisNorthboundLedger.finalize(run, population, result) do
        {:ok, finalized} -> finalized
        {:error, ledger_reason} -> ledger_failure_result(result, ledger_reason)
      end

    fail_started_run(
      source,
      run,
      result,
      actor,
      finish_run,
      update_source,
      record_event
    )
  end

  defp failure_result(device_count, reason) do
    # error_count is a source-ID outcome count. Keep run-level failures in
    # errors instead of inventing one failed device for an empty population.
    %{
      device_count: device_count,
      updated_count: 0,
      skipped_count: 0,
      error_count: device_count,
      batch_count: 0,
      errors: [%{reason: reason}]
    }
  end

  defp load_identity_conflicts(source, opts) do
    SourceIdentityDrift.source_conflict_report(source, opts)
  end

  defp default_identity_conflict_loader(opts) do
    if Keyword.has_key?(opts, :load_candidates) do
      fn _source, _opts -> SourceIdentityDrift.empty_conflict_report() end
    else
      &load_identity_conflicts/2
    end
  end

  defp attach_identity_conflicts(result, identity_conflicts) do
    total_count = SourceIdentityDrift.conflict_count(identity_conflicts)
    withheld_count = SourceIdentityDrift.withheld_conflict_count(identity_conflicts)

    if total_count == 0 do
      result
    else
      # Fold only withholding conflicts into the counts (disjoint from the sent
      # candidates), but always attach the full report for operator visibility.
      result = Map.put(result, :identity_conflicts, identity_conflicts)

      if Map.get(result, :identity_withholding_included, false) or
           Map.has_key?(result, :collection) do
        result
      else
        result
        |> Map.update(:device_count, withheld_count, &(&1 + withheld_count))
        |> Map.update(:skipped_count, withheld_count, &(&1 + withheld_count))
      end
    end
  end

  @spec execute_batches(IntegrationSource.t() | map(), [collapsed_candidate()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def execute_batches(source, candidates, opts \\ []) do
    with :ok <- northbound_ready?(source, opts) do
      do_execute_batches(source, candidates, opts)
    end
  end

  defp do_execute_batches(source, [], _opts) do
    Logger.info("Skipping Armis northbound bulk update because no candidates were loaded",
      integration_source_id: inspect(Map.get(source, :id))
    )

    {:ok,
     %{
       device_count: 0,
       updated_count: 0,
       skipped_count: 0,
       error_count: 0,
       batch_count: 0,
       errors: [],
       accepted_ids: [],
       failed_ids: [],
       unattempted_ids: []
     }}
  end

  defp do_execute_batches(source, candidates, opts) do
    request = Keyword.get(opts, :request, &default_request/5)
    custom_field = custom_field(source)
    batches = batch_candidates(candidates, batch_size(source))

    Logger.info("Fetching Armis northbound access token",
      integration_source_id: inspect(Map.get(source, :id)),
      endpoint: Map.get(source, :endpoint),
      device_count: length(candidates),
      batch_count: length(batches),
      custom_field: custom_field
    )

    case fetch_access_token(source, opts) do
      {:ok, token} ->
        Logger.info("Fetched Armis northbound access token",
          integration_source_id: inspect(Map.get(source, :id)),
          batch_count: length(batches)
        )

        composite = composite_for_run(source, candidates, opts)

        execute_bulk_batches(
          source,
          candidates,
          batches,
          custom_field,
          token,
          request,
          Keyword.put(opts, :composite, composite)
        )

      {:error, reason} ->
        Logger.warning("Failed to fetch Armis northbound access token",
          integration_source_id: inspect(Map.get(source, :id)),
          reason: inspect(reason)
        )

        {:error,
         %{
           device_count: length(candidates),
           updated_count: 0,
           skipped_count: 0,
           error_count: max(length(candidates), 1),
           batch_count: length(batches),
           errors: [%{reason: reason}],
           accepted_ids: [],
           failed_ids: [],
           unattempted_ids: candidate_ids(candidates)
         }}
    end
  end

  defp execute_bulk_batches(source, candidates, batches, custom_field, token, request, opts) do
    initial = %{
      device_count: length(candidates),
      updated_count: 0,
      skipped_count: 0,
      error_count: 0,
      batch_count: length(batches),
      errors: [],
      accepted_ids: [],
      failed_ids: [],
      unattempted_ids: [],
      token: token
    }

    result =
      batches
      |> Enum.with_index(1)
      |> Enum.reduce_while(initial, fn {batch, batch_number}, acc ->
        payload =
          build_bulk_payload(custom_field, batch,
            source: source,
            composite: Keyword.get(opts, :composite)
          )

        Logger.info("Sending Armis northbound bulk update batch",
          integration_source_id: inspect(Map.get(source, :id)),
          batch_number: batch_number,
          batch_count: length(batches),
          batch_size: length(batch),
          payload_shape: bulk_payload_shape(payload)
        )

        {request_result, token_in_effect} =
          send_bulk_batch(source, payload, acc.token, request, opts)

        acc = %{acc | token: token_in_effect}

        case request_result do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.info("Armis northbound bulk update batch accepted",
              integration_source_id: inspect(Map.get(source, :id)),
              batch_number: batch_number,
              batch_count: length(batches),
              batch_size: length(batch),
              status: status
            )

            {:cont,
             %{
               acc
               | updated_count: acc.updated_count + length(batch),
                 accepted_ids: acc.accepted_ids ++ candidate_ids(batch)
             }}

          {:ok, %{status: status, body: body}} ->
            Logger.warning("Armis northbound bulk update batch rejected",
              integration_source_id: inspect(Map.get(source, :id)),
              batch_number: batch_number,
              batch_count: length(batches),
              batch_size: length(batch),
              status: status,
              response_body: inspect(body)
            )

            error = %{batch_size: length(batch), reason: {:unexpected_status, status, body}}

            {:halt,
             %{
               acc
               | error_count: acc.error_count + length(batch),
                 failed_ids: acc.failed_ids ++ candidate_ids(batch),
                 errors: acc.errors ++ [error]
             }}

          {:error, reason} ->
            Logger.warning("Armis northbound bulk update batch failed",
              integration_source_id: inspect(Map.get(source, :id)),
              batch_number: batch_number,
              batch_count: length(batches),
              batch_size: length(batch),
              reason: inspect(reason)
            )

            error = %{batch_size: length(batch), reason: reason}

            {:halt,
             %{
               acc
               | error_count: acc.error_count + length(batch),
                 failed_ids: acc.failed_ids ++ candidate_ids(batch),
                 errors: acc.errors ++ [error]
             }}
        end
      end)
      |> Map.delete(:token)
      |> put_unattempted_ids(candidates)

    if result.errors == [] do
      {:ok, result}
    else
      {:error, result}
    end
  end

  defp put_unattempted_ids(result, candidates) do
    terminal = MapSet.new(result.accepted_ids ++ result.failed_ids)

    unattempted_ids =
      candidates
      |> candidate_ids()
      |> Enum.reject(&MapSet.member?(terminal, &1))

    %{result | unattempted_ids: unattempted_ids}
  end

  defp candidate_ids(candidates) do
    Enum.map(candidates, &to_string(Map.fetch!(&1, :armis_device_id)))
  end

  # Sends one bulk batch. Armis access tokens are short-lived, so a token minted
  # at the start of the run can expire (or be rotated) before the last batch is
  # sent. On a 401 we re-fetch the token once and retry the same batch, and we
  # return the token that was actually used so subsequent batches reuse a token
  # that was refreshed here. A persistent 401 (e.g. genuinely bad credentials)
  # still surfaces as a rejected batch after the single retry.
  defp send_bulk_batch(source, payload, token, request, opts) do
    case bulk_request(source, payload, token, request) do
      {:ok, %{status: 401}} = rejected ->
        case refresh_access_token(source, token, opts) do
          {:ok, refreshed} ->
            Logger.info("Refreshing Armis northbound access token after 401 and retrying batch",
              integration_source_id: inspect(Map.get(source, :id))
            )

            {bulk_request(source, payload, refreshed, request), refreshed}

          :unchanged ->
            {rejected, token}
        end

      result ->
        {result, token}
    end
  end

  defp refresh_access_token(source, current_token, opts) do
    case fetch_access_token(source, opts) do
      {:ok, refreshed} when is_binary(refreshed) and refreshed != current_token ->
        {:ok, refreshed}

      {:ok, _unchanged} ->
        :unchanged

      {:error, reason} ->
        Logger.warning("Failed to refresh Armis northbound access token after 401",
          integration_source_id: inspect(Map.get(source, :id)),
          reason: inspect(reason)
        )

        :unchanged
    end
  end

  defp bulk_request(source, payload, token, request) do
    request.(
      "/api/v1/devices/custom-properties/_bulk/",
      :post,
      request_headers(token),
      payload,
      request_options(source)
    )
  end

  @spec candidates_query(IntegrationSource.t() | map()) :: Ecto.Query.t()
  def candidates_query(source) do
    source_id = to_string(Map.fetch!(source, :id))
    availability_source_agent_id = availability_source_agent_id(source)

    if blank?(availability_source_agent_id) do
      canonical_candidates_query(source_id)
    else
      agent_candidates_query(source_id, availability_source_agent_id)
    end
  end

  defp canonical_candidates_query(source_id) do
    from(d in Device,
      join: di in DeviceIdentifier,
      on: di.device_id == d.uid and di.identifier_type == :armis_device_id,
      where: not is_nil(d.uid) and is_nil(d.deleted_at),
      where: ^source_linkage_predicate(source_id),
      where: ^armis_identity_present_predicate(),
      where: ^armis_identity_consistent_predicate(),
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

  defp agent_candidates_query(source_id, availability_source_agent_id) do
    from(d in Device,
      join: di in DeviceIdentifier,
      on: di.device_id == d.uid and di.identifier_type == :armis_device_id,
      join: daa in DeviceAgentAvailability,
      on: daa.device_uid == d.uid and daa.agent_id == ^availability_source_agent_id,
      where: not is_nil(d.uid) and is_nil(d.deleted_at),
      where: ^source_linkage_predicate(source_id),
      where: ^armis_identity_present_predicate(),
      where: ^armis_identity_consistent_predicate(),
      select: %{
        armis_device_id: di.identifier_value,
        is_available: fragment("COALESCE(?, false)", daa.is_available),
        device_id: d.uid,
        sync_service_id:
          fragment(
            "COALESCE(?->>'sync_service_id', ?->>'sync_service_id')",
            di.metadata,
            d.metadata
          ),
        metadata:
          fragment(
            "jsonb_strip_nulls(COALESCE(?, '{}'::jsonb) || jsonb_build_object('integration_type', COALESCE(?->>'integration_type', ?->>'integration_type'), 'availability_source_agent_id', ?::text))::jsonb",
            d.metadata,
            di.metadata,
            d.metadata,
            ^availability_source_agent_id
          )
      },
      order_by: [asc: di.identifier_value, asc: d.uid]
    )
  end

  defp source_linkage_predicate(source_id) do
    dynamic(
      [d, di],
      fragment(
        """
        COALESCE(?->>'sync_service_id', '') = ?
        OR COALESCE(?->>'sync_service_id', '') = ?
        OR (
          COALESCE(?->>'sync_service_id', '') = ''
          AND NOT EXISTS (
            SELECT 1
            FROM platform.device_identifiers source_di
            WHERE source_di.device_id = ?
              AND COALESCE(source_di.metadata->>'sync_service_id', '') <> ''
          )
        )
        """,
        d.metadata,
        ^source_id,
        di.metadata,
        ^source_id,
        d.metadata,
        d.uid
      )
    )
  end

  defp armis_identity_present_predicate do
    dynamic(
      [_d, di],
      fragment(
        "NULLIF(?, '') IS NOT NULL",
        di.identifier_value
      )
    )
  end

  defp armis_identity_consistent_predicate do
    dynamic(
      [d, di],
      fragment(
        """
        (
          NULLIF(?->>'armis_device_id', '') IS NULL
          OR ?->>'armis_device_id' = ?
        )
        AND (
          COALESCE(?->>'integration_type', '') <> 'armis'
          OR NULLIF(?->>'integration_id', '') IS NULL
          OR ?->>'integration_id' = ?
        )
        AND NOT EXISTS (
          SELECT 1
          FROM platform.device_identifiers other_armis_di
          WHERE other_armis_di.device_id = ?
            AND other_armis_di.identifier_type = 'armis_device_id'
            AND other_armis_di.identifier_value <> ?
        )
        AND NOT EXISTS (
          SELECT 1
          FROM platform.device_identifiers split_generic_di
          WHERE split_generic_di.identifier_type = 'integration_id'
            AND split_generic_di.identifier_value = ?
            AND split_generic_di.device_id <> ?
            AND COALESCE(split_generic_di.metadata->>'integration_type', '') = 'armis'
            AND (
              split_generic_di.partition = ?
              OR (
                split_generic_di.partition = 'default'
                AND COALESCE(split_generic_di.metadata->>'sync_service_id', '') =
                    COALESCE(?->>'sync_service_id', ?->>'sync_service_id', '')
              )
            )
        )
        """,
        d.metadata,
        d.metadata,
        di.identifier_value,
        d.metadata,
        d.metadata,
        d.metadata,
        di.identifier_value,
        d.uid,
        di.identifier_value,
        di.identifier_value,
        d.uid,
        di.partition,
        di.metadata,
        d.metadata
      )
    )
  end

  defp availability_source_agent_id(source) do
    Map.get(source, :northbound_availability_source_agent_id) ||
      Map.get(source, "northbound_availability_source_agent_id")
  end

  defp availability_source_ready?(source) do
    case availability_source_agent_id(source) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        if agent_availability_rows_exist?(agent_id) do
          :ok
        else
          {:error, {:missing_agent_availability, agent_id}}
        end

      _ ->
        :ok
    end
  end

  defp agent_availability_rows_exist?(agent_id) do
    DeviceAgentAvailability
    |> where([daa], daa.agent_id == ^agent_id)
    |> select([daa], 1)
    |> limit(1)
    |> Repo.exists?()
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

  @doc """
  The bulk payload for a batch of collapsed candidates.

  `opts[:composite]` is `%{custom_field: String.t(), values: %{device_uid =>
  value}}`. A device absent from `values` produces no composite output at all —
  not an empty string, not a placeholder — which is the northbound contract for
  a device outside the check's scope.
  """
  @spec build_bulk_payload(String.t(), [collapsed_candidate()], keyword()) :: [map()]
  def build_bulk_payload(custom_field, candidates, opts \\ [])
      when is_binary(custom_field) and custom_field != "" do
    composite = Keyword.get(opts, :composite)

    Enum.flat_map(candidates, fn candidate ->
      value = northbound_value(candidate.is_available)
      composite_value = composite_value_for(composite, candidate)

      case parse_armis_device_id(candidate.armis_device_id) do
        {:ok, device_id} ->
          # The upsert shape carries exactly one key per entry, so a second
          # field is a second entry rather than a second key.
          [upsert_entry(device_id, custom_field, value)] ++
            composite_upsert(device_id, composite, composite_value)

        :error ->
          properties =
            put_composite_property(%{custom_field => value}, composite, composite_value)

          [%{"id" => candidate.armis_device_id, "customProperties" => properties}]
      end
    end)
  end

  # Resolved once per run, not per batch: a read per batch would be an N+1 in
  # the number of batches, which grows with the exported device population.
  #
  # Returns nil when nothing is configured, which is exactly what
  # `build_bulk_payload/3` treats as "emit availability only".
  defp composite_for_run(source, candidates, opts) do
    case composite_export(source) do
      nil ->
        nil

      export ->
        uids = Enum.flat_map(candidates, &Map.get(&1, :device_ids, []))
        values = CompositeNorthboundValues.for_devices(export, uids, ash_opts(opts))

        Logger.info("Resolved Armis northbound composite values",
          integration_source_id: inspect(Map.get(source, :id)),
          check_slug: export.check_slug,
          value_form: export.value_form,
          device_count: length(uids),
          value_count: map_size(values)
        )

        %{custom_field: export.custom_field, values: values}
    end
  end

  # Recorded on the run, not read back from the source at display time: run
  # status must describe *that run*, and the source's selection can change after
  # it. The keys are omitted entirely when nothing is configured, so an
  # unconfigured run does not store nils that read like a failed lookup.
  defp maybe_put_composite_export(metadata, source) do
    case composite_export(source) do
      nil ->
        metadata

      export ->
        Map.merge(metadata, %{
          composite_check_slug: export.check_slug,
          composite_value_form: to_string(export.value_form),
          composite_custom_field: export.custom_field
        })
    end
  end

  # The run's actor, or a system actor for a scheduled run that has none.
  defp ash_opts(opts) do
    case Keyword.get(opts, :actor) do
      nil -> [actor: SystemActor.system(:armis_northbound)]
      actor -> [actor: actor]
    end
  end

  defp upsert_entry(device_id, key, value) do
    %{"upsert" => %{"deviceId" => device_id, "key" => key, "value" => value}}
  end

  defp composite_upsert(_device_id, _composite, nil), do: []

  defp composite_upsert(device_id, %{custom_field: field}, value) do
    [upsert_entry(device_id, field, value)]
  end

  # The customProperties shape can hold several keys, so it stays one entry per
  # device rather than splitting like the upsert form.
  defp put_composite_property(properties, _composite, nil), do: properties

  defp put_composite_property(properties, %{custom_field: field}, value) do
    Map.put(properties, field, value)
  end

  # One Armis device can collapse from several ServiceRadar UIDs, so "the"
  # composite value for it is ambiguous by construction. The first UID that has
  # a value wins, in the order `collapse_candidates/1` produced them: emitting
  # one entry per UID would be a last-writer-wins race inside a single batch,
  # and picking by map iteration order would make the winner unpredictable.
  defp composite_value_for(nil, _candidate), do: nil

  defp composite_value_for(%{values: values}, candidate) when map_size(values) > 0 do
    candidate
    |> Map.get(:device_ids, [])
    |> Enum.find_value(fn uid -> Map.get(values, uid) end)
  end

  defp composite_value_for(_composite, _candidate), do: nil

  defp northbound_value(is_available), do: to_string(not is_available)

  defp parse_armis_device_id(value) when is_integer(value), do: {:ok, value}

  defp parse_armis_device_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {device_id, ""} -> {:ok, device_id}
      _ -> :error
    end
  end

  defp parse_armis_device_id(_), do: :error

  defp bulk_payload_shape([%{"upsert" => _} | _]), do: "upsert"
  defp bulk_payload_shape([%{"id" => _, "customProperties" => _} | _]), do: "customProperties"
  defp bulk_payload_shape(_), do: "unknown"

  defp compact_unique(values) do
    values
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp finalize_success(source, run, result, actor, finish_run, update_source, record_event) do
    metadata =
      source
      |> availability_source_run_metadata()
      |> Map.merge(%{batch_count: result.batch_count, errors: serialize_errors(result.errors)})
      |> maybe_put_population(result)
      |> maybe_put_identity_conflicts(result)
      |> maybe_put_composite_export(source)

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
    metadata =
      source
      |> availability_source_run_metadata()
      |> Map.merge(%{batch_count: result.batch_count, errors: serialize_errors(result.errors)})
      |> maybe_put_population(result)
      |> maybe_put_identity_conflicts(result)
      |> maybe_put_composite_export(source)

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
      eligible_count:
        Map.get(result, :eligible_count, result.device_count - result.skipped_count),
      withheld_count: Map.get(result, :withheld_count, result.skipped_count),
      accepted_count: Map.get(result, :accepted_count, result.updated_count),
      failed_count: Map.get(result, :failed_count, result.error_count),
      unattempted_count: Map.get(result, :unattempted_count, 0),
      reconciliation_status: Map.get(result, :reconciliation_status, :unavailable),
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
        "custom_field" => custom_field(source),
        "availability_source_agent_id" => availability_source_agent_id(source) || "canonical"
      }
      |> maybe_put_string(
        "error_message",
        Map.get(result, :error_message)
      )
      |> maybe_put_population(result)
      |> maybe_put_identity_conflicts(result)

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
        "#{result.updated_count}/#{result.device_count} source IDs accepted by Armis"

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

  defp maybe_put_identity_conflicts(metadata, result) do
    case Map.get(result, :identity_conflicts) do
      %{"total_count" => count} = report when is_integer(count) and count > 0 ->
        Map.put(metadata, "identity_conflicts", report)

      %{total_count: count} = report when is_integer(count) and count > 0 ->
        Map.put(metadata, "identity_conflicts", report)

      _ ->
        metadata
    end
  end

  defp maybe_put_population(metadata, result) do
    case Map.get(result, :collection) do
      collection when is_map(collection) ->
        Map.merge(metadata, %{
          collection: collection,
          eligible_count: Map.get(result, :eligible_count, 0),
          withheld_count: Map.get(result, :withheld_count, 0),
          accepted_count: Map.get(result, :accepted_count, 0),
          failed_count: Map.get(result, :failed_count, 0),
          unattempted_count: Map.get(result, :unattempted_count, 0),
          reconciliation_status: Map.get(result, :reconciliation_status, :unavailable),
          withheld_reason_counts: Map.get(result, :withheld_reason_counts, %{})
        })

      _ ->
        metadata
    end
  end

  defp default_start_run(source, actor, opts) do
    oban_job_id = Keyword.get(opts, :oban_job_id)
    :ok = reconcile_stale_runs(source, actor, opts)

    if active_running_run_exists?(source, actor, opts) do
      Logger.info("Skipping Armis northbound run because one is already running",
        integration_source_id: inspect(Map.get(source, :id)),
        oban_job_id: oban_job_id
      )

      {:error, :northbound_run_already_active}
    else
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(
        :start_run,
        %{
          integration_source_id: Map.fetch!(source, :id),
          run_type: :armis_northbound,
          oban_job_id: oban_job_id,
          metadata: availability_source_run_metadata(source)
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
    end
  end

  defp availability_source_run_metadata(source) do
    source
    |> availability_source_agent_id()
    |> case do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        %{
          "availability_source" => "selected_agent",
          "availability_source_agent_id" => agent_id
        }

      _ ->
        %{"availability_source" => "canonical"}
    end
  end

  defp active_running_run_exists?(source, actor, opts) do
    list_runs = Keyword.get(opts, :list_runs, &list_recent_runs/2)

    source
    |> list_runs.(actor)
    |> Enum.any?(&(&1.status == :running))
  end

  def reconcile_stale_runs(source, actor, opts) do
    list_runs = Keyword.get(opts, :list_runs, &list_recent_runs/2)
    finish_run = Keyword.get(opts, :finish_run, &default_finish_run/5)
    update_source = Keyword.get(opts, :update_source, &default_update_source/4)
    oban_state = Keyword.get(opts, :oban_state, &fetch_oban_job_state/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff_seconds = Keyword.get(opts, :stale_run_cutoff_seconds, @stale_run_cutoff_seconds)

    source
    |> list_runs.(actor)
    |> Enum.filter(&stale_running_run?(&1, now, cutoff_seconds))
    |> Enum.each(fn run ->
      if orphaned_oban_state?(oban_state.(run.oban_job_id), now, cutoff_seconds) do
        case stale_run_result(run) do
          {:ok, result} ->
            finish_stale_run(source, run, result, actor, finish_run, update_source)

          {:error, reason} ->
            Logger.warning("Could not finalize stale Armis northbound ledger",
              integration_source_id: inspect(Map.get(source, :id)),
              run_id: inspect(Map.get(run, :id)),
              reason: inspect(reason)
            )
        end
      end
    end)

    :ok
  end

  defp stale_run_result(%{collection_id: collection_id} = run)
       when is_binary(collection_id) and collection_id != "" do
    ArmisNorthboundLedger.abort_pending(run)
  end

  defp stale_run_result(run) do
    {:ok,
     %{
       device_count: Map.get(run, :device_count) || 0,
       updated_count: Map.get(run, :updated_count) || 0,
       skipped_count: Map.get(run, :skipped_count) || 0,
       error_count: Map.get(run, :error_count) || 0,
       reconciliation_status: :unavailable
     }}
  end

  defp finish_stale_run(source, run, result, actor, finish_run, update_source) do
    error_message = "Marked timed out after orphaned Oban job"

    metadata =
      Map.merge(run.metadata || %{}, %{
        "reconciled" => false,
        "reason" => "orphaned_oban_job"
      })

    attrs = build_run_attrs(result, Map.put(metadata, :error_message, error_message))

    case finish_run.(run, :finish_timeout, attrs, actor, %{status: :timeout}) do
      {:ok, _finished_run} ->
        timeout_attrs = %{
          result: :timeout,
          device_count: result.device_count,
          updated_count: result.updated_count,
          skipped_count: result.skipped_count + result.error_count,
          error_message: error_message
        }

        case update_source.(source, :northbound_failed, timeout_attrs, actor) do
          {:ok, _source} -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
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

  defp orphaned_oban_state?(nil, _now, _cutoff_seconds), do: true

  defp orphaned_oban_state?(%{state: state} = job, now, cutoff_seconds) do
    cond do
      terminal_oban_state?(state) ->
        true

      state == "executing" ->
        stale_oban_attempt?(job, now, cutoff_seconds)

      true ->
        false
    end
  end

  defp orphaned_oban_state?(state, _now, _cutoff_seconds), do: terminal_oban_state?(state)

  defp terminal_oban_state?(state), do: state in ["completed", "discarded", "cancelled"]

  defp stale_oban_attempt?(%{attempted_at: %DateTime{} = attempted_at}, now, cutoff_seconds) do
    DateTime.diff(now, attempted_at, :second) >= cutoff_seconds
  end

  defp stale_oban_attempt?(%{attempted_at: %NaiveDateTime{} = attempted_at}, now, cutoff_seconds) do
    NaiveDateTime.diff(to_naive_datetime(now), attempted_at, :second) >= cutoff_seconds
  end

  defp stale_oban_attempt?(_job, _now, _cutoff_seconds), do: false

  defp to_naive_datetime(%DateTime{} = datetime), do: DateTime.to_naive(datetime)
  defp to_naive_datetime(%NaiveDateTime{} = datetime), do: datetime

  defp fetch_oban_job_state(nil), do: nil

  defp fetch_oban_job_state(oban_job_id) do
    case Repo.query(
           "select state::text, attempted_at from platform.oban_jobs where id = $1 limit 1",
           [
             oban_job_id
           ]
         ) do
      {:ok, %{rows: [[state, attempted_at]]}} -> %{state: state, attempted_at: attempted_at}
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

    case armis_secret_key(credentials) do
      secret_key when is_binary(secret_key) and secret_key != "" ->
        fetch_access_token_with_secret(source, secret_key)

      _ ->
        {:error, :missing_secret_key}
    end
  end

  defp fetch_access_token_with_secret(source, secret_key) do
    body = %{"secret_key" => secret_key}

    case default_form_request(
           "/api/v1/access_token/",
           :post,
           %{
             "content-type" => "application/x-www-form-urlencoded",
             "accept" => "application/json"
           },
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

  defp armis_secret_key(credentials) do
    Enum.find_value(
      ["secret_key", :secret_key, "api_secret", :api_secret],
      "",
      fn key ->
        case Map.get(credentials, key) do
          value when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: nil, else: value

          _ ->
            nil
        end
      end
    )
  end

  defp request_headers(token) do
    %{
      "Authorization" => authorization_header(token),
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }
  end

  # Armis authenticates bulk requests with the RAW access token returned by
  # POST /api/v1/access_token/. It rejects an `Authorization: Bearer <token>`
  # header with `401 {"message" => "Invalid access token."}`. Send the token
  # verbatim (only trimmed of whitespace) and never prepend a scheme.
  #
  # Regression history (do not "fix" this back to Bearer):
  #   f13534b81 set this to the raw token (the correct Armis behaviour),
  #   8e8b00b93 accidentally reintroduced a Bearer prefix, which shipped in
  #   v1.2.78–v1.2.83 and took down the example-namespace northbound sync for a
  #   weekend once v1.2.83 was deployed. `String.trim/1` also leaves a token
  #   that already carries a scheme untouched.
  defp authorization_header(token) when is_binary(token) do
    String.trim(token)
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

  defp default_form_request(path, method, headers, body, opts) do
    request =
      [method: method, url: path, form: body, headers: Enum.to_list(headers)]
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
