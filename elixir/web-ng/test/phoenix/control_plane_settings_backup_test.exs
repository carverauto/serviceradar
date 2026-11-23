defmodule ServiceRadarWebNGWeb.ControlPlaneSettingsBackupTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Jobs.SettingsBackupDestination
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter
  alias ServiceRadarWebNGWeb.Plugs.ControlPlaneSettingsBackup

  @moduletag :db_free

  @runtime_token "test-control-plane-runtime-token-with-more-than-32-bytes"
  @media_token "synthetic-media-installation-token-with-more-than-32-bytes"
  @deployment_ref "ce032564-a123-4bc5-89ab-000000000002"
  @authorization_header "x-serviceradar-control-plane-authorization"

  defmodule FakeState do
    @moduledoc false
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{dest: {:ok, nil}, upsert: nil, conflict: false, test_pid: nil} end,
        name: __MODULE__
      )
    end

    def get(key, default \\ nil) do
      case Process.whereis(__MODULE__) do
        nil -> default
        _pid -> Agent.get(__MODULE__, &Map.get(&1, key, default))
      end
    end

    def put(key, value) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
    end
  end

  defmodule FakeDestination do
    @moduledoc false
    def get_singleton(actor: _actor) do
      FakeState.get(:dest, {:ok, nil})
    end

    def upsert_destination(attrs, actor: _actor) do
      case FakeState.get(:upsert) do
        fun when is_function(fun, 1) ->
          fun.(attrs)

        _ ->
          record = build_record(attrs)
          FakeState.put(:dest, {:ok, record})
          {:ok, :created, record}
      end
    end

    def build_record(attrs) do
      now = ~U[2026-11-22 18:00:00Z]

      %SettingsBackupDestination{
        id: "11111111-1111-4111-8111-111111111111",
        key: "default",
        provider: Map.get(attrs, :provider, "linode_object_storage"),
        endpoint: Map.fetch!(attrs, :endpoint),
        bucket: Map.fetch!(attrs, :bucket),
        region: Map.fetch!(attrs, :region),
        prefix: Map.get(attrs, :prefix, ""),
        enabled: Map.get(attrs, :enabled, false),
        schedule_cron: Map.get(attrs, :schedule_cron, "0 */6 * * *"),
        credentials_configured: true,
        next_run_at: now,
        last_exported_at: nil,
        last_export_status: nil,
        last_export_error: nil,
        last_export_object_key: nil,
        last_export_etag: nil,
        last_export_sha256: nil,
        updated_at: now
      }
    end
  end

  defmodule FakeEnqueuer do
    @moduledoc false
    def enqueue_export(_dest, params) do
      if pid = FakeState.get(:test_pid) do
        send(pid, {:enqueued_export, params})
      end

      conflict? = FakeState.get(:conflict, false)
      {:ok, %Oban.Job{id: 4242, conflict?: conflict?}}
    end
  end

  setup do
    start_supervised!(FakeState)
    FakeState.put(:test_pid, self())

    prev_runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    prev_dest_mod = Application.get_env(:serviceradar_web_ng, :settings_backup_destination_module)
    prev_enq_mod = Application.get_env(:serviceradar_web_ng, :settings_backup_enqueuer_module)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @runtime_token,
      port: 4001,
      media: [token: @media_token, deployment_ref: @deployment_ref, generation: "1"]
    )

    Application.put_env(:serviceradar_web_ng, :settings_backup_destination_module, FakeDestination)
    Application.put_env(:serviceradar_web_ng, :settings_backup_enqueuer_module, FakeEnqueuer)

    on_exit(fn ->
      restore_env(:control_plane_runtime, prev_runtime)
      restore_env(:settings_backup_destination_module, prev_dest_mod)
      restore_env(:settings_backup_enqueuer_module, prev_enq_mod)
    end)

    :ok
  end

  test "rejects missing or media-scoped bearer tokens" do
    conn =
      :get
      |> conn("/v1/settings-backup/destination")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert conn.status == 401

    media_conn =
      :get
      |> conn("/v1/settings-backup/destination")
      |> put_req_header(@authorization_header, "Bearer " <> @media_token)
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert media_conn.status == 401
  end

  test "GET /v1/settings-backup/destination returns 404 when unconfigured and 200 without secrets when configured" do
    FakeState.put(:dest, {:ok, nil})

    missing = authed_conn(:get, "/v1/settings-backup/destination")
    assert missing.status == 404

    record = %{
      FakeDestination.build_record(%{
        endpoint: "https://us-east-1.linodeobjects.com",
        bucket: "synthetic-bucket",
        region: "us-east-1",
        enabled: true
      })
      | last_exported_at: ~U[2026-11-22 17:00:00Z],
        last_export_status: "succeeded",
        last_export_object_key: "settings-export/20261122T170000Z-abcdef123456.json",
        last_export_etag: "\"etag-1\"",
        last_export_sha256: String.duplicate("a", 64),
        access_key_id: "AKIA_MUST_NOT_LEAK",
        secret_access_key: "secret-must-not-leak"
    }

    FakeState.put(:dest, {:ok, record})
    found = authed_conn(:get, "/v1/settings-backup/destination")
    assert found.status == 200
    body = Jason.decode!(found.resp_body)
    assert body["data"]["bucket"] == "synthetic-bucket"
    assert body["data"]["credentials_configured"] == true
    assert body["data"]["last_export_status"] == "succeeded"
    refute Map.has_key?(body["data"], "access_key_id")
    refute Map.has_key?(body["data"], "secret_access_key")
    refute String.contains?(found.resp_body, "AKIA_MUST_NOT_LEAK")
    refute String.contains?(found.resp_body, "secret-must-not-leak")
  end

  test "PUT /v1/settings-backup/destination validates media type, size, duplicate keys, unknown keys, and upserts" do
    wrong_ct =
      :put
      |> conn("/v1/settings-backup/destination", "{}")
      |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
      |> put_req_header("content-type", "text/plain")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert wrong_ct.status == 415

    dup_keys =
      :put
      |> conn("/v1/settings-backup/destination", ~s({"bucket":"a","bucket":"b"}))
      |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
      |> put_req_header("content-type", "application/json")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert dup_keys.status == 400

    oversized =
      :put
      |> conn("/v1/settings-backup/destination", String.duplicate("x", 70_000))
      |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
      |> put_req_header("content-type", "application/json")
      |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))

    assert oversized.status == 413

    unknown = authed_json(:put, "/v1/settings-backup/destination", %{"unexpected" => true})
    assert unknown.status == 400

    valid_payload = %{
      "endpoint" => "https://us-east-1.linodeobjects.com",
      "bucket" => "synthetic-bucket",
      "region" => "us-east-1",
      "prefix" => "tenant-a",
      "access_key_id" => "AKIA_SYNTHETIC_PUT",
      "secret_access_key" => "synthetic-secret-put",
      "enabled" => true,
      "schedule_cron" => "0 */6 * * *"
    }

    created = authed_json(:put, "/v1/settings-backup/destination", valid_payload)
    assert created.status == 201
    decoded = Jason.decode!(created.resp_body)
    assert decoded["data"]["bucket"] == "synthetic-bucket"
    assert decoded["data"]["credentials_configured"] == true
    refute String.contains?(created.resp_body, "AKIA_SYNTHETIC_PUT")
    refute String.contains?(created.resp_body, "synthetic-secret-put")
  end

  test "POST /v1/settings-backup/export returns 409 when unconfigured/disabled and 202 when queued" do
    FakeState.put(:dest, {:ok, nil})
    unconfigured = authed_conn(:post, "/v1/settings-backup/export")
    assert unconfigured.status == 409

    disabled_record =
      FakeDestination.build_record(%{
        endpoint: "https://us-east-1.linodeobjects.com",
        bucket: "synthetic-bucket",
        region: "us-east-1",
        enabled: false
      })

    FakeState.put(:dest, {:ok, disabled_record})
    disabled = authed_conn(:post, "/v1/settings-backup/export")
    assert disabled.status == 409

    enabled_record = %{disabled_record | enabled: true}
    FakeState.put(:dest, {:ok, enabled_record})

    invalid_reason =
      authed_json(:post, "/v1/settings-backup/export", %{"reason" => "not_allowed"})

    assert invalid_reason.status == 400

    FakeState.put(:conflict, false)

    queued =
      authed_json(:post, "/v1/settings-backup/export", %{
        "reason" => "pre_resize",
        "idempotency_key" => "  resize-op-123  "
      })

    assert queued.status == 202
    body = Jason.decode!(queued.resp_body)
    assert body["data"]["status"] == "queued"
    assert body["data"]["deduplicated"] == false
    assert body["data"]["job_id"] == 4242
    assert is_binary(body["data"]["requested_at"])
    assert_received {:enqueued_export, %{reason: "pre_resize", idempotency_key: "resize-op-123"}}

    FakeState.put(:conflict, true)

    deduped =
      authed_json(:post, "/v1/settings-backup/export", %{
        "reason" => "pre_resize",
        "idempotency_key" => "resize-op-123"
      })

    assert deduped.status == 202
    deduped_body = Jason.decode!(deduped.resp_body)
    assert deduped_body["data"]["status"] == "queued"
    assert deduped_body["data"]["deduplicated"] == true
    assert deduped_body["data"]["job_id"] == 4242
    assert_received {:enqueued_export, %{reason: "pre_resize", idempotency_key: "resize-op-123"}}
  end

  test "live Bandit listener serves port-4001 settings-backup endpoints over HTTP with auth and guards" do
    {:ok, _} = Application.ensure_all_started(:inets)

    listener =
      start_supervised!(
        {Bandit, plug: ControlPlaneRuntimeRouter, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(listener)
    auth = [{String.to_charlist(@authorization_header), String.to_charlist("Bearer " <> @runtime_token)}]

    # Auth enforcement over real TCP (missing, standard Authorization, media token).
    for headers <- [
          [],
          [{~c"authorization", String.to_charlist("Bearer " <> @runtime_token)}],
          [{String.to_charlist(@authorization_header), String.to_charlist("Bearer " <> @media_token)}]
        ] do
      assert {:ok, 401, _hdrs, %{"status" => "unauthorized"}, _raw} =
               live_http(:get, port, "/v1/settings-backup/destination", headers)
    end

    # Unconfigured destination -> 404 on GET, 409 on POST export.
    FakeState.put(:dest, {:ok, nil})

    assert {:ok, 404, _hdrs, %{"status" => "not_found"}, _raw} =
             live_http(:get, port, "/v1/settings-backup/destination", auth)

    assert {:ok, 409, _hdrs, %{"status" => "destination_not_configured"}, _raw} =
             live_http(:post, port, "/v1/settings-backup/export", auth, "application/json", "{}")

    # PUT validation guards over real HTTP: 415 wrong media type, 400 duplicate key, 413 oversized.
    assert {:ok, 415, _hdrs, %{"status" => "unsupported_media_type"}, _raw} =
             live_http(:put, port, "/v1/settings-backup/destination", auth, "text/plain", "{}")

    assert {:ok, 400, _hdrs, %{"status" => "invalid_request"}, _raw} =
             live_http(
               :put,
               port,
               "/v1/settings-backup/destination",
               auth,
               "application/json",
               ~s({"bucket":"a","bucket":"b"})
             )

    assert {:ok, 413, _hdrs, %{"status" => "request_too_large"}, _raw} =
             live_http(
               :put,
               port,
               "/v1/settings-backup/destination",
               auth,
               "application/json",
               String.duplicate("x", 70_000)
             )

    # Valid PUT creates destination and never echoes credentials.
    put_body =
      Jason.encode!(%{
        "endpoint" => "https://us-east-1.linodeobjects.com",
        "bucket" => "synthetic-bandit-bucket",
        "region" => "us-east-1",
        "prefix" => "tenant-live",
        "access_key_id" => "AKIA_LIVE_BANDIT_KEY",
        "secret_access_key" => "synthetic-live-bandit-secret",
        "enabled" => true,
        "schedule_cron" => "0 */6 * * *"
      })

    assert {:ok, 201, put_hdrs, %{"data" => created_data}, raw_put} =
             live_http(:put, port, "/v1/settings-backup/destination", auth, "application/json", put_body)

    assert header_value(put_hdrs, "cache-control") == "no-store"
    assert header_value(put_hdrs, "x-content-type-options") == "nosniff"
    assert created_data["bucket"] == "synthetic-bandit-bucket"
    assert created_data["credentials_configured"] == true
    refute String.contains?(raw_put, "AKIA_LIVE_BANDIT_KEY")
    refute String.contains?(raw_put, "synthetic-live-bandit-secret")

    # GET reads back configured destination without credentials.
    assert {:ok, 200, _hdrs, %{"data" => fetched_data}, raw_get} =
             live_http(:get, port, "/v1/settings-backup/destination", auth)

    assert fetched_data["bucket"] == "synthetic-bandit-bucket"
    refute String.contains?(raw_get, "AKIA_LIVE_BANDIT_KEY")
    refute String.contains?(raw_get, "synthetic-live-bandit-secret")

    # POST export queues job and reports deduplicated flag cleanly.
    FakeState.put(:conflict, false)
    export_body = Jason.encode!(%{"reason" => "pre_resize", "idempotency_key" => "  live-resize-1  "})

    assert {:ok, 202, _hdrs, %{"data" => queued}, _raw} =
             live_http(:post, port, "/v1/settings-backup/export", auth, "application/json", export_body)

    assert queued["status"] == "queued"
    assert queued["deduplicated"] == false
    assert queued["job_id"] == 4242
    assert_received {:enqueued_export, %{reason: "pre_resize", idempotency_key: "live-resize-1"}}

    FakeState.put(:conflict, true)

    assert {:ok, 202, _hdrs, %{"data" => deduped}, _raw} =
             live_http(:post, port, "/v1/settings-backup/export", auth, "application/json", export_body)

    assert deduped["status"] == "queued"
    assert deduped["deduplicated"] == true
    assert deduped["job_id"] == 4242
    assert_received {:enqueued_export, %{reason: "pre_resize", idempotency_key: "live-resize-1"}}
  end

  test "build_export_job configures Oban uniqueness on idempotency_key when present" do
    dest =
      FakeDestination.build_record(%{
        endpoint: "https://us-east-1.linodeobjects.com",
        bucket: "synthetic-bucket",
        region: "us-east-1",
        enabled: true
      })

    cs_with_key =
      ControlPlaneSettingsBackup.build_export_job(dest, %{
        reason: "pre_resize",
        idempotency_key: "resize-op-123"
      })

    assert cs_with_key.valid?
    assert cs_with_key.changes.args[:idempotency_key] == "resize-op-123"
    assert cs_with_key.changes.args[:action_arguments]["idempotency_key"] == "resize-op-123"
    assert cs_with_key.changes.unique.fields == [:worker, :args]
    assert cs_with_key.changes.unique.keys == [:idempotency_key]
    assert cs_with_key.changes.unique.period == 86_400
    assert cs_with_key.changes.unique.states == Oban.Job.unique_states(:successful)

    cs_without_key =
      ControlPlaneSettingsBackup.build_export_job(dest, %{
        reason: "manual",
        idempotency_key: nil
      })

    assert cs_without_key.valid?
    refute Map.has_key?(cs_without_key.changes.args, :idempotency_key)
    refute Map.has_key?(cs_without_key.changes.args, "idempotency_key")
    assert cs_without_key.changes.unique.states == Oban.Job.unique_states(:incomplete)
  end

  defp authed_conn(method, path) do
    method
    |> conn(path)
    |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
    |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))
  end

  defp authed_json(method, path, payload) do
    method
    |> conn(path, Jason.encode!(payload))
    |> put_req_header(@authorization_header, "Bearer " <> @runtime_token)
    |> put_req_header("content-type", "application/json")
    |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))
  end

  defp live_http(method, port, path, headers, content_type \\ nil, body \\ nil) do
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

    req =
      case {method, content_type, body} do
        {:get, _, _} -> {url, headers}
        {_, ct, b} -> {url, headers, String.to_charlist(ct || "application/json"), b || ""}
      end

    case :httpc.request(method, req, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, Jason.decode!(resp_body), resp_body}

      other ->
        other
    end
  end

  defp header_value(headers, target) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == target, do: to_string(value)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
