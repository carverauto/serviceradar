defmodule ServiceRadar.ResultsRouterLargeIngestionReleaseGateTest do
  @moduledoc """
  Release-gate coverage for large sync status ingestion through DIRE into inventory.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag :large_ingestion
  # Each chunk must commit independently: Armis identifier ownership uses
  # transaction-scoped advisory locks, which a test-wide sandbox owner retains.
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)

    previous_batch_concurrency =
      Application.get_env(:serviceradar_core, :sync_ingestor_batch_concurrency)

    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)
    Application.put_env(:serviceradar_core, :sync_ingestor_batch_concurrency, 1)

    # Drives handle_cast/2 directly with a bare %{} state asserting synchronous
    # ingestion; disable async batching for the per-item path.
    Application.put_env(:serviceradar_core, :results_router_batching, false)

    on_exit(fn ->
      if is_nil(previous_async) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_async)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor_async, previous_async)
      end

      if is_nil(previous_batching) do
        Application.delete_env(:serviceradar_core, :results_router_batching)
      else
        Application.put_env(:serviceradar_core, :results_router_batching, previous_batching)
      end

      if is_nil(previous_batch_concurrency) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_batch_concurrency)
      else
        Application.put_env(
          :serviceradar_core,
          :sync_ingestor_batch_concurrency,
          previous_batch_concurrency
        )
      end
    end)

    :ok
  end

  @tag timeout: 1_800_000
  test "large Armis sync chunks route through results router into inventory" do
    count = large_ingestion_device_count()
    chunk_size = large_ingestion_chunk_size()
    run_id = Ash.UUID.generate()
    source = create_armis_source!()
    sync_service_id = source.id
    total_chunks = ceil_div(count, chunk_size)

    population = %{
      "raw_rows" => count,
      "excluded_rows" => 0,
      "invalid_rows" => 0,
      "valid_occurrences" => count,
      "distinct_source_ids" => count,
      "duplicate_occurrences" => 0,
      "conflicting_duplicate_ids" => 0
    }

    for chunk_index <- 0..(total_chunks - 1) do
      start_index = chunk_index * chunk_size + 1
      end_index = min(start_index + chunk_size - 1, count)
      is_final = chunk_index == total_chunks - 1

      updates =
        Enum.map(start_index..end_index, fn device_number ->
          ip = large_ingestion_ip(device_number)
          label = if device_number <= div(count, 2), do: "release-gate-a", else: "release-gate-b"

          %{
            "device_id" => "default:#{ip}",
            "ip" => ip,
            "hostname" => "armis-release-gate-#{device_number}",
            "source" => "armis",
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
            "metadata" => %{
              "armis_device_id" => Integer.to_string(device_number),
              "integration_type" => "armis",
              "query_label" => label
            },
            "sync_meta" =>
              maybe_put_population(
                %{
                  "sync_service_id" => sync_service_id,
                  "sync_run_id" => run_id,
                  "chunk_index" => chunk_index,
                  "total_chunks" => total_chunks,
                  "total_devices" => count,
                  "is_final" => is_final
                },
                is_final,
                population
              )
          }
        end)

      status = %{
        source: "results",
        service_type: "sync",
        service_name: "sync",
        agent_id: "agent-large-ingestion",
        gateway_id: "gateway-large-ingestion",
        partition: "default",
        chunk_index: chunk_index,
        total_chunks: total_chunks,
        is_final: is_final,
        message: Jason.encode!(updates)
      }

      assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    end

    assert 0 ==
             scalar_count!(
               "SELECT COUNT(*)::bigint FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()",
               []
             ),
           "large ingestion must commit between chunks so transaction-scoped advisory locks are released"

    assert count ==
             scalar_count!(
               """
               SELECT COUNT(*)::bigint
               FROM platform.ocsf_devices
               WHERE metadata->>'sync_service_id' = $1
                 AND metadata->>'sync_run_id' = $2
               """,
               [sync_service_id, run_id]
             )

    assert count ==
             scalar_count!(
               """
               SELECT COUNT(*)::bigint
               FROM platform.device_identifiers
               WHERE identifier_type = 'armis_device_id'
                 AND metadata->>'sync_service_id' = $1
               """,
               [sync_service_id]
             )

    assert div(count, 2) ==
             scalar_count!(
               """
               SELECT COUNT(*)::bigint
               FROM platform.ocsf_devices
               WHERE metadata->>'sync_service_id' = $1
                 AND metadata->>'query_label' = 'release-gate-a'
               """,
               [sync_service_id]
             )

    # The final chunk's `population` accounting (added above) is what lets
    # `ServiceRadar.Inventory.ArmisSourceSnapshot.activate/3` run at all --
    # without it, `validate_population/1` rejects the sync_meta and
    # activation never happens, silently (a `Results processing failed`
    # warning log, not a raised error or a failed assertion). Assert the
    # snapshot this run's activation is supposed to produce actually landed,
    # so a regression here fails loudly instead of going unnoticed again.
    assert 1 ==
             scalar_count!(
               """
               SELECT COUNT(*)::bigint
               FROM platform.device_source_snapshots
               WHERE source = 'armis'
                 AND source_instance = $1
                 AND collection_id = $2
               """,
               [sync_service_id, run_id]
             ),
           "expected ArmisSourceSnapshot.activate/3 to record a device_source_snapshots row for this run"
  end

  defp system_actor do
    SystemActor.system(:test)
  end

  defp maybe_put_population(sync_meta, true, population),
    do: Map.put(sync_meta, "population", population)

  defp maybe_put_population(sync_meta, false, _population), do: sync_meta

  defp create_armis_source! do
    actor = system_actor()
    uid = "agent-large-ingestion-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "armis-large-ingestion-gate-#{System.unique_integer([:positive])}",
        source_type: :armis,
        endpoint: "https://armis-large-ingestion-gate.test",
        agent_id: uid
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp large_ingestion_device_count do
    env_integer("SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT", 50_000)
  end

  defp large_ingestion_chunk_size do
    env_integer("SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE", 1_000)
  end

  defp env_integer(name, fallback) do
    case System.get_env(name) do
      nil ->
        fallback

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> fallback
        end
    end
  end

  defp ceil_div(left, right), do: div(left + right - 1, right)

  defp large_ingestion_ip(device_number) do
    "10.#{1 + rem(div(device_number, 65_536), 200)}.#{rem(div(device_number, 256), 256)}.#{rem(device_number, 256)}"
  end

  defp scalar_count!(sql, params) do
    %{rows: [[count]]} = Repo.query!(sql, params)
    count
  end
end
