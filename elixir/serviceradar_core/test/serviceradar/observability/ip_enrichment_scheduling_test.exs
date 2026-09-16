defmodule ServiceRadar.Observability.IpEnrichmentSchedulingTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Observability.GeoLiteMmdbDownloadWorker
  alias ServiceRadar.Observability.IpEnrichmentRefreshWorker
  alias ServiceRadar.Observability.IpinfoMmdbDownloadWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @mmdb_workers [GeoLiteMmdbDownloadWorker, IpinfoMmdbDownloadWorker]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    # Never created, so every MMDB file counts as missing.
    missing_dir = Path.join(System.tmp_dir!(), "mmdb-#{System.unique_integer([:positive])}")
    previous = Map.new(@mmdb_workers, &{&1, Application.get_env(:serviceradar_core, &1)})

    Enum.each(@mmdb_workers, fn worker ->
      Application.put_env(:serviceradar_core, worker, enabled: true, dir: missing_dir)
    end)

    on_exit(fn -> Enum.each(previous, &restore_config/1) end)

    Enum.each([IpEnrichmentRefreshWorker | @mmdb_workers], &delete_jobs/1)
    :ok
  end

  test "missing MMDB files promote a download scheduled before the backoff window" do
    for worker <- @mmdb_workers do
      download = insert_scheduled_job!(worker, 43_200)
      backdate_inserted_at!(download, 43_200)

      assert {:ok, :already_scheduled} = worker.ensure_scheduled()
      assert [%Oban.Job{id: id, scheduled_at: scheduled_at}] = jobs(worker)
      assert id == download.id
      assert DateTime.compare(scheduled_at, DateTime.utc_now()) != :gt
    end
  end

  # A successor inserted inside the backoff window comes from a run that just ended without the
  # files, typically a failed download. Promoting it on every scheduler tick would retry about
  # once a minute instead of backing off.
  test "missing MMDB files leave a recent backoff successor at its scheduled time" do
    for worker <- @mmdb_workers do
      backoff = insert_scheduled_job!(worker, 21_600)

      assert {:ok, _job} = worker.ensure_scheduled()
      assert [%Oban.Job{id: id, scheduled_at: scheduled_at}] = jobs(worker)
      assert id == backoff.id
      assert DateTime.compare(scheduled_at, backoff.scheduled_at) == :eq
    end
  end

  test "ensure_scheduled/0 rescues only refresh jobs executing past the stale threshold" do
    now = DateTime.utc_now()
    stale = insert_executing_refresh_job!(DateTime.add(now, -7_200, :second))
    running = insert_executing_refresh_job!(now)
    expected = %{stale.id => "available", running.id => "executing"}

    assert {:ok, :already_scheduled} = IpEnrichmentRefreshWorker.ensure_scheduled()
    assert job_states(IpEnrichmentRefreshWorker) == expected
  end

  defp insert_scheduled_job!(worker, schedule_in) do
    %{}
    |> worker.new(schedule_in: schedule_in)
    |> Repo.insert!()
  end

  defp insert_executing_refresh_job!(attempted_at) do
    %{}
    |> IpEnrichmentRefreshWorker.new()
    |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: attempted_at)
    |> Repo.insert!()
  end

  defp backdate_inserted_at!(%Oban.Job{id: id}, seconds) do
    inserted_at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    query = from(job in Oban.Job, where: job.id == ^id)

    {1, _} = Repo.update_all(query, set: [inserted_at: inserted_at])
  end

  defp jobs(worker) do
    worker_name = Oban.Worker.to_string(worker)

    Repo.all(from(job in Oban.Job, where: job.worker == ^worker_name))
  end

  defp job_states(worker) do
    worker
    |> jobs()
    |> Map.new(&{&1.id, &1.state})
  end

  defp delete_jobs(worker) do
    worker_name = Oban.Worker.to_string(worker)
    Repo.delete_all(from(job in Oban.Job, where: job.worker == ^worker_name))
  end

  defp restore_config({worker, nil}), do: Application.delete_env(:serviceradar_core, worker)

  defp restore_config({worker, config}),
    do: Application.put_env(:serviceradar_core, worker, config)
end
