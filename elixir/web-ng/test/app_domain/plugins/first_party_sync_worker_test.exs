defmodule ServiceRadarWebNG.Plugins.FirstPartySyncWorkerTest do
  @moduledoc """
  Guards how per-repository sync outcomes fold into the Oban job result.

  The rule is easy to break by accident and fails silently when broken: a
  retryable failure (expired token, HTTP 5xx, invalid settings) that folds to
  `:ok` never retries, while a failure describing the published release itself
  that folds to an error re-reports the same thing on all three Oban attempts.
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker

  @moduletag :db_free

  test "all successful repositories succeed the job" do
    assert :ok = FirstPartySyncWorker.aggregate_results([:ok, :ok])
  end

  test "an empty repository list succeeds the job" do
    assert :ok = FirstPartySyncWorker.aggregate_results([])
  end

  test "a missing release catalog alone does not fail the job" do
    results = [
      :ok,
      {:error, "Release tag v1.4.51 was not found"},
      {:error, "Repository or releases not found"}
    ]

    assert :ok = FirstPartySyncWorker.aggregate_results(results)
  end

  test "a retryable string failure fails the job even beside a missing catalog" do
    results = [
      {:error, "Release tag v1.4.51 was not found"},
      {:error, "Release import failed with HTTP 502"}
    ]

    assert {:error, :partial_plugin_sync_failure} =
             FirstPartySyncWorker.aggregate_results(results)
  end

  test "an atom failure reason fails the job" do
    assert {:error, :partial_plugin_sync_failure} =
             FirstPartySyncWorker.aggregate_results([:ok, {:error, :invalid_attributes}])
  end
end
