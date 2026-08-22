defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerTimeoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker

  test "nist-nvd2 is allowed a 60-minute Oban timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}) == 3_600_000
  end

  test "other feeds keep the 3-minute timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "vulncheck-kev"}}) == 180_000
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
      # Worst case: every attempt burns the full nist-nvd2 timeout before failing.
      timeout_s = div(FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}), 1000)
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
