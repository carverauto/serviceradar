defmodule ServiceRadar.Observability.NetflowDatasetRefreshWorkerIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Observability.{
    NetflowOuiDatasetRefreshWorker,
    NetflowProviderDatasetRefreshWorker
  }

  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    clear_dataset_tables()
    :ok
  end

  test "provider refresh promotes snapshot on success and keeps last-known-good on failure" do
    payload =
      Jason.encode!([
        %{"cidr" => "1.1.1.0/24", "provider" => "cloudflare", "ip_version" => "IPv4"},
        %{"cidr" => "10.10.0.0/16", "provider" => "aws", "ip_version" => "IPv4"}
      ])

    {url, stop_server} = start_http_fixture(payload, "application/json", 200)

    on_exit(fn -> stop_server.() end)

    with_worker_env(NetflowProviderDatasetRefreshWorker,
      source_url: url,
      timeout_ms: 200,
      reschedule_seconds: 60,
      failure_reschedule_seconds: 60
    )

    assert :ok = NetflowProviderDatasetRefreshWorker.perform(%Oban.Job{args: %{}})

    %{id: active_id, record_count: 2} = active_provider_snapshot!()
    assert provider_prefix_count(active_id) == 2

    with_worker_env(NetflowProviderDatasetRefreshWorker,
      source_url: "http://127.0.0.1:9/provider.json",
      timeout_ms: 50,
      reschedule_seconds: 60,
      failure_reschedule_seconds: 60
    )

    assert :ok = NetflowProviderDatasetRefreshWorker.perform(%Oban.Job{args: %{}})

    %{id: still_active_id, record_count: 2} = active_provider_snapshot!()
    assert still_active_id == active_id
    assert provider_prefix_count(still_active_id) == 2
  end

  test "oui csv refresh promotes snapshot on success and keeps last-known-good on failure" do
    csv =
      "Registry,Assignment,Organization Name,Organization Address\n" <>
        "MA-L,001122,Example Vendor A,Address A\n" <>
        "MA-L,AABBCC,Example Vendor B,Address B\n"

    {url, stop_server} = start_http_fixture(csv, "application/octet-stream", 200)

    on_exit(fn -> stop_server.() end)

    with_worker_env(NetflowOuiDatasetRefreshWorker,
      source_url: url,
      timeout_ms: 200,
      reschedule_seconds: 60,
      failure_reschedule_seconds: 60
    )

    assert :ok = NetflowOuiDatasetRefreshWorker.perform(%Oban.Job{args: %{}})

    %{id: active_id, record_count: 2} = active_oui_snapshot!()
    assert oui_prefix_count(active_id) == 2

    with_worker_env(NetflowOuiDatasetRefreshWorker,
      source_url: "http://127.0.0.1:9/oui.csv",
      timeout_ms: 50,
      reschedule_seconds: 60,
      failure_reschedule_seconds: 60
    )

    assert :ok = NetflowOuiDatasetRefreshWorker.perform(%Oban.Job{args: %{}})

    %{id: still_active_id, record_count: 2} = active_oui_snapshot!()
    assert still_active_id == active_id
    assert oui_prefix_count(still_active_id) == 2
  end

  defp with_worker_env(worker, overrides) when is_list(overrides) do
    previous = Application.get_env(:serviceradar_core, worker)
    Application.put_env(:serviceradar_core, worker, overrides)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, worker)
      else
        Application.put_env(:serviceradar_core, worker, previous)
      end
    end)
  end

  defp clear_dataset_tables do
    Repo.query!("DELETE FROM platform.netflow_provider_cidrs", [])
    Repo.query!("DELETE FROM platform.netflow_provider_dataset_snapshots", [])
    Repo.query!("DELETE FROM platform.netflow_oui_prefixes", [])
    Repo.query!("DELETE FROM platform.netflow_oui_dataset_snapshots", [])
  end

  defp active_provider_snapshot! do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, record_count FROM platform.netflow_provider_dataset_snapshots WHERE is_active = TRUE LIMIT 1",
        []
      )

    case rows do
      [[id, count]] -> %{id: id, record_count: count}
      _ -> flunk("expected active provider snapshot")
    end
  end

  defp active_oui_snapshot! do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, record_count FROM platform.netflow_oui_dataset_snapshots WHERE is_active = TRUE LIMIT 1",
        []
      )

    case rows do
      [[id, count]] -> %{id: id, record_count: count}
      _ -> flunk("expected active OUI snapshot")
    end
  end

  defp provider_prefix_count(snapshot_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM platform.netflow_provider_cidrs WHERE snapshot_id = $1",
        [snapshot_id]
      )

    count
  end

  defp oui_prefix_count(snapshot_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM platform.netflow_oui_prefixes WHERE snapshot_id = $1",
        [snapshot_id]
      )

    count
  end

  defp start_http_fixture(body, content_type, status)
       when is_binary(body) and is_binary(content_type) and is_integer(status) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}])

    {:ok, port} = :inet.port(listen_socket)

    {:ok, pid} =
      Task.start_link(fn ->
        http_accept_loop(listen_socket, body, content_type, status)
      end)

    stop = fn ->
      try do
        Process.exit(pid, :normal)
        :gen_tcp.close(listen_socket)
        :ok
      rescue
        _ -> :ok
      end
    end

    {"http://127.0.0.1:#{port}/fixture", stop}
  end

  defp http_accept_loop(listen_socket, body, content_type, status) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, _request} -> :ok
            {:error, :timeout} -> :ok
            {:error, _reason} -> :ok
          end

        response =
          [
            "HTTP/1.1 ",
            Integer.to_string(status),
            " OK\\r\\n",
            "Content-Type: ",
            content_type,
            "\\r\\n",
            "Content-Length: ",
            Integer.to_string(byte_size(body)),
            "\\r\\n",
            "Connection: close\\r\\n\\r\\n",
            body
          ]
          |> IO.iodata_to_binary()

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        http_accept_loop(listen_socket, body, content_type, status)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end
end
