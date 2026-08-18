defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerTimeoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker

  test "nist-nvd2 is allowed a 60-minute Oban timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}) == 3_600_000
  end

  test "other feeds keep the 3-minute timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "vulncheck-kev"}}) == 180_000
  end
end
