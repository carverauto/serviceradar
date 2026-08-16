defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerOrphanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker

  test "live_owner_names stringifies the local node set" do
    owners = FeedWorker.live_owner_names([:"serviceradar_core@10.42.51.169"])

    assert "serviceradar_core@10.42.51.169" in owners
  end

  test "an executing job whose owner is gone is an orphan" do
    job = executing_job("nist-nvd2", "serviceradar_core@10.42.51.165", seconds_ago: 60)

    assert FeedWorker.orphan_executing_job?(
             job,
             MapSet.new(["serviceradar_core@10.42.51.169"])
           )
  end

  test "an executing job owned by a live node is not an orphan" do
    job = executing_job("nist-nvd2", "serviceradar_core@10.42.51.169", seconds_ago: 60)

    refute FeedWorker.orphan_executing_job?(
             job,
             MapSet.new(["serviceradar_core@10.42.51.169"])
           )
  end

  test "a live nist-nvd2 job older than the 65-minute reclaim window is an orphan" do
    job =
      executing_job("nist-nvd2", "serviceradar_core@10.42.51.169", seconds_ago: 66 * 60)

    assert FeedWorker.orphan_executing_job?(
             job,
             MapSet.new(["serviceradar_core@10.42.51.169"])
           )
  end

  test "resume_plan reuses an extract and in-progress generation" do
    extract = %{extracted_dir: System.tmp_dir!(), run_dir: System.tmp_dir!()}

    assert {:reuse, plan} =
             FeedWorker.resume_plan(
               %{"generation" => 18, "last_completed_shard" => "nvdcve-2.0-040.json.gz"},
               extract,
               18,
               "abc"
             )

    assert plan.generation == 18
    assert plan.after_shard == "nvdcve-2.0-040.json.gz"
  end

  test "resume_plan downloads when no extract is on disk" do
    assert FeedWorker.resume_plan(nil, nil, nil, "abc") == :download
  end

  test "a scheduled job is never treated as an executing orphan" do
    job = %{
      state: "scheduled",
      args: %{"feed" => "nist-nvd2"},
      attempted_by: ["serviceradar_core@10.42.51.165"],
      attempted_at: DateTime.utc_now()
    }

    refute FeedWorker.orphan_executing_job?(job, MapSet.new())
  end

  defp executing_job(feed, owner, seconds_ago: seconds_ago) do
    %{
      state: "executing",
      args: %{"feed" => feed},
      attempted_by: [owner],
      attempted_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    }
  end
end
