defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerSchedulingTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedDefinitionSeeder
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_advisory_feeds = Application.fetch_env(:serviceradar_core, :advisory_feeds)

    Application.put_env(
      :serviceradar_core,
      :advisory_feeds,
      Keyword.merge(advisory_feeds_config(previous_advisory_feeds),
        advisory_feeds_core_enabled: true,
        advisory_feeds_nist_nvd2_enabled: true
      )
    )

    on_exit(fn ->
      delete_feed_worker_jobs()
      restore_env(:advisory_feeds, previous_advisory_feeds)
    end)

    assert :ok = FeedDefinitionSeeder.seed_defaults()
    enable_feed!("cisa", "cisa-kev", 3_600)
    enable_feed!("nvd", "nist-nvd2", 7_200)

    :ok
  end

  test "an executing feed job leaves one scheduled successor at the configured cadence" do
    executing = insert_executing_job!("nist-nvd2")
    put_advisory_feed_config(:advisory_feeds_nist_nvd2_enabled, false)

    before_perform = DateTime.utc_now()
    assert :ok = FeedWorker.perform(%{executing | args: %{"feed" => "nist-nvd2"}})
    after_perform = DateTime.utc_now()

    successors =
      Repo.all(
        from(job in Oban.Job,
          where: job.worker == ^inspect(FeedWorker),
          where: fragment("?->>'feed' = ?", job.args, "nist-nvd2"),
          where: job.id != ^executing.id and job.state == "scheduled"
        )
      )

    assert [%Oban.Job{conflict?: false, args: %{"feed" => "nist-nvd2"}} = successor] =
             successors

    scheduled_from = DateTime.add(successor.scheduled_at, -7_200, :second)

    assert DateTime.compare(scheduled_from, before_perform) in [:eq, :gt]
    assert DateTime.compare(scheduled_from, after_perform) in [:eq, :lt]
  end

  test "reconciliation keeps an existing future successor" do
    future = insert_scheduled_job!("cisa-kev", 3_600)
    future_id = future.id

    assert {:ok, :scheduled} = FeedWorker.ensure_scheduled()
    assert [%Oban.Job{id: ^future_id, state: "scheduled"}] = jobs_for("cisa-kev")
    assert DateTime.diff(hd(jobs_for("cisa-kev")).scheduled_at, DateTime.utc_now()) > 3_500
  end

  defp enable_feed!(provider, feed_key, refresh_interval_seconds) do
    actor = SystemActor.system(:feed_worker_scheduling_test)

    definition =
      VulnerabilityFeedDefinition
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
      |> Ash.read_one!(actor: actor)

    definition
    |> Ash.Changeset.for_update(
      :update,
      %{enabled: true, refresh_interval_seconds: refresh_interval_seconds},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp insert_executing_job!(feed) do
    now = DateTime.utc_now()

    %{"feed" => feed}
    |> Oban.Job.new(worker: FeedWorker, queue: :integrations)
    |> Ecto.Changeset.change(
      state: "executing",
      attempt: 1,
      max_attempts: 4,
      attempted_at: now,
      inserted_at: now,
      scheduled_at: now
    )
    |> Repo.insert!()
  end

  defp insert_scheduled_job!(feed, schedule_in) do
    %{feed: feed}
    |> FeedWorker.new(schedule_in: schedule_in)
    |> Repo.insert!()
  end

  defp jobs_for(feed) do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == ^inspect(FeedWorker),
        where: fragment("?->>'feed' = ?", job.args, ^feed)
      )
    )
  end

  defp delete_feed_worker_jobs do
    Repo.delete_all(from(job in Oban.Job, where: job.worker == ^inspect(FeedWorker)))
  end

  defp put_advisory_feed_config(key, value) do
    config = Application.fetch_env!(:serviceradar_core, :advisory_feeds)
    Application.put_env(:serviceradar_core, :advisory_feeds, Keyword.put(config, key, value))
  end

  defp advisory_feeds_config({:ok, config}), do: config
  defp advisory_feeds_config(:error), do: []

  defp restore_env(key, {:ok, value}), do: Application.put_env(:serviceradar_core, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:serviceradar_core, key)
end
