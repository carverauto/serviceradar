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

  defmodule FakeDestination do
    @moduledoc false
    def get_singleton(actor: _actor) do
      Process.get(:fake_settings_backup_dest, {:ok, nil})
    end

    def upsert_destination(attrs, actor: _actor) do
      case Process.get(:fake_settings_backup_upsert) do
        fun when is_function(fun, 1) -> fun.(attrs)
        _ -> {:ok, :created, build_record(attrs)}
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
      send(self(), {:enqueued_export, params})
      {:ok, %Oban.Job{id: 4242}}
    end
  end

  setup do
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
    Process.put(:fake_settings_backup_dest, {:ok, nil})

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

    Process.put(:fake_settings_backup_dest, {:ok, record})
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
    Process.put(:fake_settings_backup_dest, {:ok, nil})
    unconfigured = authed_conn(:post, "/v1/settings-backup/export")
    assert unconfigured.status == 409

    disabled_record =
      FakeDestination.build_record(%{
        endpoint: "https://us-east-1.linodeobjects.com",
        bucket: "synthetic-bucket",
        region: "us-east-1",
        enabled: false
      })

    Process.put(:fake_settings_backup_dest, {:ok, disabled_record})
    disabled = authed_conn(:post, "/v1/settings-backup/export")
    assert disabled.status == 409

    enabled_record = %{disabled_record | enabled: true}
    Process.put(:fake_settings_backup_dest, {:ok, enabled_record})

    invalid_reason =
      authed_json(:post, "/v1/settings-backup/export", %{"reason" => "not_allowed"})

    assert invalid_reason.status == 400

    queued =
      authed_json(:post, "/v1/settings-backup/export", %{
        "reason" => "pre_resize",
        "idempotency_key" => "  resize-op-123  "
      })

    assert queued.status == 202
    body = Jason.decode!(queued.resp_body)
    assert body["data"]["status"] == "queued"
    assert body["data"]["job_id"] == 4242
    assert is_binary(body["data"]["requested_at"])
    assert_received {:enqueued_export, %{reason: "pre_resize", idempotency_key: "resize-op-123"}}
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
