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
    # be enqueued behind it. Node names here are serviceradar_core@<pod-ip>, so a
    # replaced pod never reuses one -- which makes node liveness a decisive test
    # that needs no age threshold.
    test "a job whose node left the cluster is orphaned" do
      live = MapSet.new(["serviceradar_core@10.42.0.1", "serviceradar_core@10.42.0.2"])

      assert FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.9.9"), live)
    end

    test "a job on a live node is never orphaned" do
      live = MapSet.new(["serviceradar_core@10.42.0.1"])

      refute FeedWorker.orphaned?(executing_on("serviceradar_core@10.42.0.1"), live),
             "reclaiming a job that is still running would double-run the feed"
    end

    # Unknown provenance is left to Oban.Plugins.Lifeline rather than guessed at.
    test "a job with no attempted_by is left alone" do
      refute FeedWorker.orphaned?(%Oban.Job{attempted_by: nil}, MapSet.new(["a@b"]))
      refute FeedWorker.orphaned?(%Oban.Job{attempted_by: []}, MapSet.new(["a@b"]))
    end

    # The safety property. Un-clustered, Node.list/0 is empty and every job would
    # look orphaned, so the fast path must not run at all. ExUnit runs without a
    # node name, which is exactly that case.
    test "does nothing on an un-clustered node" do
      assert Node.self() == :nonode@nohost, "precondition: this test must run un-clustered"
      assert FeedWorker.reclaim_orphaned_jobs() == :ok
    end

    # The real shape, verified against the live cluster: Oban 2.23 writes
    # attempted_by as [node, uuid] -- two elements, not the [node, queue, uuid]
    # of older versions. orphaned?/2 matches the head so both work, and this
    # asserts that rather than leaving it to a comment.
    test "reads the node from either attempted_by shape" do
      live = MapSet.new(["serviceradar_core@10.42.0.1"])
      gone = "serviceradar_core@10.42.9.9"

      assert FeedWorker.orphaned?(%Oban.Job{attempted_by: [gone, "uuid"]}, live)
      assert FeedWorker.orphaned?(%Oban.Job{attempted_by: [gone, "integrations", "uuid"]}, live)
    end

    defp executing_on(node) do
      %Oban.Job{state: "executing", attempted_by: [node, "uuid"]}
    end
  end
end
