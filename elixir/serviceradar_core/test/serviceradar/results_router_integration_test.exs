defmodule ServiceRadar.ResultsRouterIntegrationTest do
  @moduledoc """
  Integration coverage for sync status ingestion through DIRE into inventory.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.TestSupport

  @moduletag :integration

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

  test "sync status update creates device and identifiers" do
    actor = system_actor()

    armis_id = "armis-#{System.unique_integer([:positive])}"
    ip_octet = rem(System.unique_integer([:positive]), 200) + 10
    ip = "10.0.0.#{ip_octet}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "edge-#{ip_octet}",
      "metadata" => %{"armis_device_id" => armis_id}
    }

    identity_update = %{
      device_id: nil,
      ip: ip,
      mac: mac,
      hostname: "edge-#{ip_octet}",
      partition: "default",
      metadata: %{"armis_device_id" => armis_id}
    }

    assert {:ok, expected_id} =
             IdentityReconciler.resolve_device_id(identity_update, actor: actor)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([update])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert {:ok, device} =
             Device.get_by_uid(expected_id, false, actor: actor)

    assert device.ip == ip
    assert device.hostname == "edge-#{ip_octet}"
    assert device.uid == expected_id

    identifier_query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default"
      })

    assert {:ok, [identifier | _]} =
             Ash.read(identifier_query, actor: actor)

    assert identifier.device_id == expected_id
  end

  @tag :large_ingestion
  @tag timeout: 1_800_000
  test "large Armis sync chunks route through results router into inventory" do
    count = large_ingestion_device_count()
    chunk_size = large_ingestion_chunk_size()
    run_id = Ash.UUID.generate()
    sync_service_id = "large-ingestion-#{System.unique_integer([:positive])}"
    total_chunks = ceil_div(count, chunk_size)

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
            "sync_meta" => %{
              "sync_service_id" => sync_service_id,
              "sync_run_id" => run_id,
              "chunk_index" => chunk_index,
              "total_chunks" => total_chunks,
              "total_devices" => count,
              "is_final" => is_final
            }
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
  end

  defp system_actor do
    SystemActor.system(:test)
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

  defp mac_suffix do
    [:positive]
    |> System.unique_integer()
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
