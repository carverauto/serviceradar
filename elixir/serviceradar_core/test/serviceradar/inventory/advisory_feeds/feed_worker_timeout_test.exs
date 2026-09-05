defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerTimeoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker
  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader

  test "preflight treats parser skips as errors instead of a complete partial snapshot" do
    records_factory = fn -> [{:record, %{id: 1}}, :skip, {:record, %{id: 2}}] end

    completeness = FeedWorker.preflight(records_factory, "records", [])

    assert completeness.complete_snapshot? == false
    assert completeness.source_objects_seen == 2
    assert completeness.parse_errors == 1
  end

  describe "prior-snapshot retention floor" do
    test "guards only the three replace-on-absence feeds with a ceiling 90 percent floor" do
      for feed <- ["cisa-kev", "vulncheck-kev", "nist-nvd2"] do
        assert {91,
                %{
                  "policy" => "prior_complete_retention",
                  "prior_count" => 101,
                  "minimum_count" => 91,
                  "retained_percent" => 90
                }} = FeedWorker.snapshot_minimum(feed, 101, 1)
      end

      assert {1, nil} = FeedWorker.snapshot_minimum("ubuntu-osv-vex", 101, 1)
      assert {1, nil} = FeedWorker.snapshot_minimum("other-feed", 101, 1)
    end

    test "keeps the absolute minimum and first-load minimum" do
      assert {250, %{"minimum_count" => 250}} =
               FeedWorker.snapshot_minimum("nist-nvd2", 100, 250)

      assert {1, %{"prior_count" => 0, "minimum_count" => 1}} =
               FeedWorker.snapshot_minimum("cisa-kev", 0, 1)
    end

    test "one-shot operator approval accepts a legitimate contraction and records the bypass" do
      assert {1,
              %{
                "policy" => "operator_approved_contraction",
                "prior_count" => 100,
                "minimum_count" => 1,
                "default_minimum_count" => 90,
                "retained_percent" => 90
              }} =
               FeedWorker.snapshot_minimum("nist-nvd2", 100, 1, accept_snapshot_contraction: true)

      assert {90, %{"policy" => "prior_complete_retention"}} =
               FeedWorker.snapshot_minimum("nist-nvd2", 100, 1)
    end

    test "one-shot operator approval cannot carry into a retry acquisition" do
      assert %Ecto.Changeset{changes: %{max_attempts: 1}} =
               FeedWorker.job_changeset("nist-nvd2", accept_snapshot_contraction: true)

      assert %Ecto.Changeset{changes: %{max_attempts: 4}} =
               FeedWorker.job_changeset("nist-nvd2", [])
    end

    test "preflight rejection includes structured prior, observed, and minimum evidence" do
      floor = %{
        "policy" => "prior_complete_retention",
        "prior_count" => 100,
        "minimum_count" => 90,
        "retained_percent" => 90
      }

      records_factory = fn -> List.duplicate({:record, %{synthetic: true}}, 89) end

      completeness =
        FeedWorker.preflight(records_factory, "records",
          expected_minimum: 90,
          retained_count_floor: floor
        )

      assert completeness.retained_count_floor["observed_count"] == 89

      assert {:error,
              {:incomplete_snapshot,
               [
                 {:below_expected_minimum,
                  %{
                    "prior_count" => 100,
                    "observed_count" => 89,
                    "minimum_count" => 90,
                    "retained_percent" => 90
                  }}
               ]}} = Loader.validate_completeness(completeness)
    end
  end

  test "status attrs preserve completion metadata on failure and expose it on success" do
    now = ~U[2026-09-02 12:00:00Z]
    failure = FeedWorker.result_status_attrs({:error, :incomplete_snapshot}, now)

    assert failure.last_status == "error"
    assert failure.last_failure_at == now
    refute Map.has_key?(failure, :last_success_at)
    refute Map.has_key?(failure, :metadata)

    completed_at = ~U[2026-09-02 11:59:00Z]

    success =
      FeedWorker.result_status_attrs(
        {:ok,
         %{
           advisories_upserted: 3,
           coordinates_upserted: 4,
           assertions_upserted: 5,
           advisories_skipped: 2,
           source_objects_seen: 5,
           parse_errors: 0,
           read_errors: 0,
           generation: 42,
           complete_generation_at: completed_at,
           validation: %{"records" => %{"complete" => true, "count" => 5}}
         }},
        now
      )

    assert success.last_status == "success"
    assert success.last_success_at == completed_at
    assert success.metadata["assertions"] == 5
    assert success.metadata["source_objects_seen"] == 5
    assert success.metadata["read_errors"] == 0
    assert success.metadata["generation"] == 42
    assert success.metadata["complete_generation_at"] == "2026-09-02T11:59:00Z"
    assert success.metadata["validation"]["records"]["complete"]
  end

  test "nist-nvd2 is allowed a 60-minute Oban timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}) == 3_600_000
  end

  test "other feeds keep the 3-minute timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "vulncheck-kev"}}) == 180_000
  end

  test "Ubuntu full-corpus job gets a bounded 75-minute timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "ubuntu-osv-vex"}}) == 4_500_000
  end

  test "Ubuntu is a first-class worker feed and uses string-keyed Oban args" do
    assert "ubuntu-osv-vex" in FeedWorker.feeds()

    assert %{"feed" => "ubuntu-osv-vex"} =
             %{"feed" => "ubuntu-osv-vex"}
             |> FeedWorker.new()
             |> Ecto.Changeset.get_change(:args)
  end

  describe "backoff/1" do
    # The regression. On 2026-08-22 a brief VulnCheck timeout consumed all three
    # attempts of a nist-nvd2 run inside 65 seconds (03:08:28, 03:09:12,
    # 03:09:33) under Oban's default backoff, discarding the job and leaving the
    # feed idle until the next 6-hour tick. Every retry sampled the same
    # one-minute window of upstream health, which is the part that made it
    # useless.
    test "spreads retries across a window that can outlast an upstream blip" do
      total = Enum.sum(Enum.map(1..3, &FeedWorker.backoff(job(&1))))

      assert total > 30 * 60,
             "three retries inside #{total}s would sample one short window of upstream " <>
               "health, which is exactly how a transient failure killed the feed"
    end

    test "each attempt waits longer than the last" do
      delays = Enum.map(1..3, &FeedWorker.backoff(job(&1)))

      assert delays == Enum.sort(delays), "backoff must be monotonic, got #{inspect(delays)}"
      assert Enum.all?(delays, &(&1 >= 60)), "no retry should land inside a minute"
    end

    test "stays within one 6-hour refresh cycle" do
      # Worst case: every attempt burns the longest feed timeout before failing.
      timeout_s =
        ["nist-nvd2", "ubuntu-osv-vex"]
        |> Enum.map(&FeedWorker.timeout(%Oban.Job{args: %{"feed" => &1}}))
        |> Enum.max()
        |> div(1000)

      attempts = 4
      worst = attempts * timeout_s + Enum.sum(Enum.map(1..3, &FeedWorker.backoff(job(&1))))

      assert worst < 6 * 60 * 60,
             "a failing run must finish retrying before the next cycle is due, got #{worst}s"
    end

    test "jitter keeps each delay near its base without collapsing to a constant" do
      # Three feeds share one upstream; identical delays would retry in lockstep.
      samples = Enum.map(1..50, fn _ -> FeedWorker.backoff(job(1)) end)

      assert Enum.min(samples) >= 108 and Enum.max(samples) <= 132,
             "expected ~120s +/-10%, got #{Enum.min(samples)}..#{Enum.max(samples)}"

      assert Enum.uniq(samples) != [hd(samples)], "delays must be jittered, not constant"
    end

    test "attempts past the schedule clamp to the longest delay" do
      assert_in_delta FeedWorker.backoff(job(9)), FeedWorker.backoff(job(3)), 400
    end

    defp job(attempt), do: %Oban.Job{attempt: attempt, args: %{"feed" => "nist-nvd2"}}
  end

  describe "orphan reclaim" do
    # A pod replaced mid-run leaves its Oban row in `executing` forever, and the
    # worker's unique constraint covers every incomplete state, so nothing new can
    # be enqueued behind it. `live` maps a live node name to the DateTime its VM
    # started, or nil when that could not be read.
    @job_at ~U[2026-08-22 06:04:00Z]

    test "a job whose node left the cluster is orphaned" do
      live = %{"serviceradar_core@10.42.0.1" => booted_before()}

      assert FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.9.9"), live)
    end

    test "a job on a live node that has not restarted is not orphaned" do
      live = %{"serviceradar_core@10.42.0.1" => booted_before()}

      refute FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.0.1"), live),
             "reclaiming a job that is still running would double-run the feed"
    end

    # The case the first version of this missed. An OOMKill restarts the container
    # inside the same pod, so the pod keeps its IP and the BEAM returns under the
    # identical node name -- liveness alone cannot tell it apart from a healthy
    # node. Observed on farm01: a nist-nvd2 run OOMKilled four minutes in, then sat
    # `executing` for over an hour behind a node name that looked fine.
    test "a job is orphaned when its node restarted after the attempt began" do
      live = %{"serviceradar_core@10.42.0.1" => DateTime.add(@job_at, 260, :second)}

      assert FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.0.1"), live),
             "a VM that booted after the attempt cannot be the one running it"
    end

    # An RPC timeout must not be able to cancel a live 60-minute feed run.
    test "a node whose start time could not be read is treated as healthy" do
      live = %{"serviceradar_core@10.42.0.1" => nil}

      refute FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.0.1"), live)
    end

    # Unknown provenance is left to Oban.Plugins.Lifeline rather than guessed at.
    test "a job with no attempted_by is left alone" do
      live = %{"serviceradar_core@10.42.0.1" => booted_before()}

      refute FeedWorker.orphaned?(%Oban.Job{attempted_by: nil, attempted_at: @job_at}, live)
      refute FeedWorker.orphaned?(%Oban.Job{attempted_by: [], attempted_at: @job_at}, live)
    end

    # Nor is a row with no attempted_at, which cannot be compared against a boot.
    test "a job with no attempted_at is left alone" do
      live = %{"serviceradar_core@10.42.0.1" => DateTime.utc_now()}

      refute FeedWorker.orphaned?(
               %Oban.Job{
                 attempted_by: ["serviceradar_core@10.42.0.1", "uuid"],
                 attempted_at: nil
               },
               live
             )
    end

    # The real shape, verified against the live cluster: Oban 2.23 writes
    # attempted_by as [node, uuid] -- two elements, not the [node, queue, uuid]
    # of older versions. orphaned?/2 matches the head so both work.
    test "reads the node from either attempted_by shape" do
      live = %{"serviceradar_core@10.42.0.1" => booted_before()}
      gone = "serviceradar_core@10.42.9.9"

      assert FeedWorker.orphaned?(
               %Oban.Job{attempted_by: [gone, "uuid"], attempted_at: @job_at},
               live
             )

      assert FeedWorker.orphaned?(
               %Oban.Job{attempted_by: [gone, "integrations", "uuid"], attempted_at: @job_at},
               live
             )
    end

    test "vm_started_at/0 reports a time in the past" do
      started_at = FeedWorker.vm_started_at()

      assert DateTime.before?(started_at, DateTime.utc_now())
      assert DateTime.diff(DateTime.utc_now(), started_at) >= 0
    end

    # The safety property. Un-clustered, Node.list/0 is empty and every job would
    # look orphaned, so the fast path must not run at all. ExUnit runs without a
    # node name, which is exactly that case.
    test "does nothing on an un-clustered node" do
      assert Node.self() == :nonode@nohost, "precondition: this test must run un-clustered"
      assert FeedWorker.reclaim_orphaned_jobs() == :ok
    end

    defp booted_before, do: DateTime.add(@job_at, -600, :second)

    defp executing_on(node) do
      %Oban.Job{state: "executing", attempted_by: [node, "uuid"], attempted_at: @job_at}
    end
  end
end
