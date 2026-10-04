defmodule ServiceRadar.Observability.ThreatIntelOTXSyncWorkerTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelOTXSyncWorker
  alias ServiceRadar.Observability.ThreatIntelSyncStatus
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous = Application.get_env(:serviceradar_core, ThreatIntelOTXSyncWorker, [])

    Application.put_env(:serviceradar_core, ThreatIntelOTXSyncWorker,
      provider: __MODULE__.FailingProvider,
      provider_config: %{"api_key" => "ignored-environment-token"}
    )

    on_exit(fn ->
      delete_jobs()
      Application.put_env(:serviceradar_core, ThreatIntelOTXSyncWorker, previous)
    end)

    delete_jobs()
    :ok
  end

  test "ensure_scheduled keeps a single future run" do
    assert {:ok, %Oban.Job{}} =
             ThreatIntelOTXSyncWorker.ensure_scheduled(schedule_in: 120, force: true)

    assert {:ok, :already_scheduled} =
             ThreatIntelOTXSyncWorker.ensure_scheduled(schedule_in: 120, force: true)

    assert length(incomplete_jobs()) == 1
  end

  test "ensure_scheduled cancels a second pending chain" do
    insert_job!(%{})
    insert_job!(%{"cursor" => %{"page" => 2}})

    assert {:ok, :already_scheduled} =
             ThreatIntelOTXSyncWorker.ensure_scheduled(force: true)

    jobs = incomplete_jobs()
    assert length(jobs) == 1
    assert Enum.any?(jobs, &(&1.state in ["scheduled", "available"]))
  end

  test "edge mode does not start the core chain and core mode does" do
    set_execution_mode!("edge_plugin")

    assert {:ok, :disabled} = ThreatIntelOTXSyncWorker.ensure_scheduled()
    assert incomplete_jobs() == []

    set_execution_mode!("core_worker")

    assert {:ok, %Oban.Job{}} = ThreatIntelOTXSyncWorker.ensure_scheduled(schedule_in: 3_600)
    assert length(incomplete_jobs()) == 1
  end

  test "a failed fetch records the failure and keeps the last success and indicator" do
    set_execution_mode!("core_worker")
    actor = SystemActor.system(:threat_intel_otx_sync_worker_test)
    source = "otx-sync-#{System.unique_integer([:positive])}"
    success_at = ~U[2026-07-14 12:00:00.000000Z]
    ip = "198.51.100.44"

    ThreatIntelIndicator
    |> Ash.Changeset.for_create(:upsert, %{
      indicator: "#{ip}/32",
      indicator_type: "cidr",
      source: source,
      label: "Synthetic pulse #{source}",
      severity: 40,
      first_seen_at: success_at,
      last_seen_at: success_at
    })
    |> Ash.create!(actor: actor)

    ThreatIntelSyncStatus
    |> Ash.Changeset.for_create(:upsert, %{
      provider: "alienvault_otx",
      source: "alienvault_otx",
      collection_id: "otx:pulses:subscribed",
      agent_id: "",
      gateway_id: "",
      plugin_id: "alienvault-otx-core",
      execution_mode: "core_worker",
      last_status: "ok",
      last_message: "previous page",
      last_attempt_at: success_at,
      last_success_at: success_at,
      objects_count: 4,
      indicators_count: 4,
      skipped_count: 0,
      total_count: 4,
      cursor: %{"modified_since" => "2026-07-12T12:00:00Z", "complete" => "true"},
      metadata: %{}
    })
    |> Ash.create!(actor: actor)

    assert {:error, :unavailable} = ThreatIntelOTXSyncWorker.perform(%Oban.Job{args: %{}})

    assert {:ok, %Oban.Job{}} = ThreatIntelOTXSyncWorker.ensure_scheduled(schedule_in: 3_600)

    indicator =
      ThreatIntelIndicator
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(source == ^source)
      |> Ash.read_one!(actor: actor)

    assert indicator.label == "Synthetic pulse #{source}"

    status =
      ThreatIntelSyncStatus
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        source == "alienvault_otx" and plugin_id == "alienvault-otx-core" and
          collection_id == "otx:pulses:subscribed"
      )
      |> Ash.read_one!(actor: actor)

    assert status.last_status == "error"
    assert status.last_error == "unavailable"
    assert status.last_success_at == success_at
    assert status.objects_count == 4
    assert status.cursor["modified_since"] == "2026-07-12T12:00:00Z"
    assert %DateTime{} = status.last_failure_at
  end

  defmodule FailingProvider do
    @moduledoc false
    def fetch_page(%{"api_key" => "synthetic-otx-key"}, _cursor), do: {:error, :unavailable}
  end

  defp set_execution_mode!(mode) do
    actor = SystemActor.system(:threat_intel_otx_sync_worker_test)

    secret = ServiceRadar.Credentials.NetworkCredentialSecret.create_secret!(%{
      name: "Synthetic OTX #{System.unique_integer([:positive])}", provider: "alienvault-otx-core",
      credential_kind: :api_token, secret_payload: "synthetic-otx-key"
    }, actor: actor)
    attrs = %{otx_enabled: true, otx_execution_mode: mode, otx_credential_secret_id: secret.id}

    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = settings} ->
        settings
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update!(actor: actor)

      {:ok, nil} ->
        NetflowSettings
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create!(actor: actor)
    end
  end

  defp insert_job!(args) do
    args
    |> ThreatIntelOTXSyncWorker.new(schedule_in: 600)
    |> Repo.insert!()
  end

  defp incomplete_jobs do
    worker = Oban.Worker.to_string(ThreatIntelOTXSyncWorker)

    Repo.all(
      from(job in Oban.Job,
        where: job.worker == ^worker,
        where: job.state in ["available", "scheduled", "executing", "retryable"]
      )
    )
  end

  defp delete_jobs do
    worker = Oban.Worker.to_string(ThreatIntelOTXSyncWorker)
    Repo.delete_all(from(job in Oban.Job, where: job.worker == ^worker))
  end
end
