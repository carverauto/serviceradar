defmodule ServiceRadarWebNGWeb.ControlPlaneSettingsBackupDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  @account_token "synthetic-backup-account-token-with-more-than-32-bytes"
  @synthetic_access_key "AKIA_SYNTHETIC_BANDIT_KEY"
  @synthetic_secret_key "synthetic-bandit-secret-key"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime, token: @account_token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)

      ServiceRadar.Repo.query!("DELETE FROM platform.settings_backup_destinations WHERE key = 'default'", [])

      job_ids = Process.get(:queued_settings_backup_job_ids, [])

      if job_ids != [] do
        ServiceRadar.Repo.query!("DELETE FROM platform.oban_jobs WHERE id = ANY($1)", [job_ids])
      end
    end)

    {:ok, _} = Application.ensure_all_started(:req)

    listener =
      start_supervised!({Bandit, plug: ControlPlaneRuntimeRouter, scheme: :http, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_addr, port}} = ThousandIsland.listener_info(listener)
    %{port: port}
  end

  test "PUT/GET destination and POST export round-trip through Bandit into CNPG and Oban", ctx do
    headers = [{"x-serviceradar-control-plane-authorization", "Bearer " <> @account_token}]
    base = "http://127.0.0.1:#{ctx.port}"

    missing = Req.get!("#{base}/v1/settings-backup/destination", headers: headers, retry: false)
    assert missing.status == 404

    not_ready = Req.post!("#{base}/v1/settings-backup/export", headers: headers, retry: false)
    assert not_ready.status == 409

    payload = %{
      "endpoint" => "https://us-east-1.linodeobjects.com",
      "bucket" => "synthetic-tenant-bucket",
      "region" => "us-east-1",
      "prefix" => "/tenant-bandit/",
      "access_key_id" => @synthetic_access_key,
      "secret_access_key" => @synthetic_secret_key,
      "enabled" => true,
      "schedule_cron" => "0 */6 * * *"
    }

    created = Req.put!("#{base}/v1/settings-backup/destination", headers: headers, json: payload, retry: false)
    assert created.status == 201
    assert created.body["data"]["bucket"] == "synthetic-tenant-bucket"
    assert created.body["data"]["prefix"] == "tenant-bandit"
    assert created.body["data"]["credentials_configured"] == true
    refute inspect(created.body) =~ @synthetic_access_key
    refute inspect(created.body) =~ @synthetic_secret_key

    # Updating schedule_cron without re-sending credentials preserves credentials_configured.
    updated =
      Req.put!(
        "#{base}/v1/settings-backup/destination",
        headers: headers,
        json: payload |> Map.drop(["access_key_id", "secret_access_key"]) |> Map.put("schedule_cron", "30 */12 * * *"),
        retry: false
      )

    assert updated.status == 200
    assert updated.body["data"]["schedule_cron"] == "30 */12 * * *"
    assert updated.body["data"]["credentials_configured"] == true

    fetched = Req.get!("#{base}/v1/settings-backup/destination", headers: headers, retry: false)
    assert fetched.status == 200
    assert fetched.body["data"]["id"] == created.body["data"]["id"]
    refute inspect(fetched.body) =~ @synthetic_access_key
    refute inspect(fetched.body) =~ @synthetic_secret_key

    exported =
      Req.post!(
        "#{base}/v1/settings-backup/export",
        headers: headers,
        json: %{"reason" => "manual"},
        retry: false
      )

    assert exported.status == 202
    assert exported.body["data"]["status"] == "queued"
    job_id = exported.body["data"]["job_id"]
    assert is_integer(job_id)
    Process.put(:queued_settings_backup_job_ids, [job_id])

    assert %{rows: [["maintenance", 0, args]]} =
             ServiceRadar.Repo.query!(
               "SELECT queue, priority, args FROM platform.oban_jobs WHERE id = $1",
               [job_id]
             )

    assert args["action_arguments"]["manual"] == true
    assert args["action_arguments"]["reason"] == "manual"

    # Repeated exports with the same idempotency_key deduplicate to the same Oban job.
    idem_first =
      Req.post!(
        "#{base}/v1/settings-backup/export",
        headers: headers,
        json: %{"reason" => "pre_resize", "idempotency_key" => "bandit-idem-1"},
        retry: false
      )

    assert idem_first.status == 202
    idem_job_id = idem_first.body["data"]["job_id"]
    refute idem_job_id == job_id

    idem_second =
      Req.post!(
        "#{base}/v1/settings-backup/export",
        headers: headers,
        json: %{"reason" => "manual", "idempotency_key" => "bandit-idem-1"},
        retry: false
      )

    assert idem_second.status == 202
    assert idem_second.body["data"]["job_id"] == idem_job_id

    idem_distinct =
      Req.post!(
        "#{base}/v1/settings-backup/export",
        headers: headers,
        json: %{"reason" => "manual", "idempotency_key" => "bandit-idem-2"},
        retry: false
      )

    assert idem_distinct.status == 202
    distinct_job_id = idem_distinct.body["data"]["job_id"]
    refute distinct_job_id == idem_job_id
    Process.put(:queued_settings_backup_job_ids, [job_id, idem_job_id, distinct_job_id])
  end
end
