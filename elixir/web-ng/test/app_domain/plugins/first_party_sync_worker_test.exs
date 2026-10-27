defmodule ServiceRadarWebNG.Plugins.FirstPartySyncWorkerTest do
  @moduledoc """
  Guards how per-repository sync outcomes fold into the Oban job result.

  The rule is easy to break by accident and fails silently when broken: a
  retryable failure (expired token, HTTP 5xx, invalid settings) that folds to
  `:ok` never retries, while a failure describing the published release itself
  that folds to an error re-reports the same thing on all three Oban attempts.
  """

  use ExUnit.Case, async: false

  alias Oban.Job
  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker
  alias ServiceRadarWebNG.Plugins.ImportFailureMessages
  alias ServiceRadarWebNG.Plugins.NativeAddonSyncWorker

  @moduletag :db_free

  # The shape the release client returns once it knows which host the egress
  # proxy refused.
  defp refused_407(host) do
    ImportFailureMessages.with_refused_host(
      {:could_not_establish_ssl_tunnel, {~c"HTTP/1.1", 407, ~c"Request rejected by proxy"}},
      host
    )
  end

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

  describe "sync_summary/3" do
    test "a clean run records counts and the release tag" do
      summary = %{
        discovered: 16,
        import_ready: 16,
        imported: 16,
        skipped: 0,
        failed: []
      }

      result =
        FirstPartySyncWorker.sync_summary(summary, "v9.9.9", %{repo_url: "https://github.com/example/serviceradar"})

      assert result["status"] == "success"
      assert result["release_tag"] == "v9.9.9"
      assert result["imported"] == 16
      assert result["failed_count"] == 0
      refute Map.has_key?(result, "first_error")
    end

    test "a run with import failures records the first failure as operator text" do
      summary = %{
        discovered: 2,
        import_ready: 2,
        imported: 0,
        skipped: 0,
        failed: [
          %{
            plugin_id: "example-plugin",
            version: "1.2.3",
            release_tag: "v9.9.9",
            error: refused_407("github-releases.githubusercontent.com")
          },
          %{plugin_id: "other-plugin", version: "0.1.0", release_tag: "v9.9.9", error: :timeout}
        ]
      }

      result =
        FirstPartySyncWorker.sync_summary(summary, "v9.9.9", %{repo_url: "https://github.com/example/serviceradar"})

      assert result["status"] == "partial"
      assert result["failed_count"] == 2
      assert result["first_error"]["plugin_id"] == "example-plugin"

      assert result["first_error"]["reason"] =~
               "egress proxy rejected the connection to github-releases.githubusercontent.com"
    end
  end

  describe "error_summary/3" do
    test "maps the failure reason for a run that never imported" do
      result =
        FirstPartySyncWorker.error_summary(
          refused_407("registry.carverauto.dev"),
          "v9.9.9",
          %{repo_url: "https://github.com/example/serviceradar"}
        )

      assert result["status"] == "failed"
      assert result["error"] =~ "egress proxy rejected the connection to registry.carverauto.dev"
    end
  end

  describe "sync_event_attrs/2" do
    test "carries the alerting key and the mapped first failure" do
      summary = %{
        "release_tag" => "v9.9.9",
        "imported" => 0,
        "skipped" => 0,
        "failed_count" => 1,
        "first_error" => %{
          "plugin_id" => "example-plugin",
          "version" => "1.2.3",
          "reason" => "egress proxy rejected the connection to registry.carverauto.dev (HTTP 407)"
        }
      }

      attrs = FirstPartySyncWorker.sync_event_attrs(%{repo_url: "https://github.com/example/serviceradar"}, summary)

      assert attrs[:status_code] == "first_party_plugin_sync_failed"
      assert attrs[:message] =~ "example-plugin"
      assert attrs[:message] =~ "egress proxy rejected"
      assert attrs[:severity_id] >= 3
    end
  end

  describe "repository_version_stale?/2" do
    test "a repository synced for the current version is not stale" do
      refute FirstPartySyncWorker.repository_version_stale?(
               %{last_sync_summary: %{"release_tag" => "v9.9.9"}},
               "v9.9.9"
             )
    end

    test "a repository synced for another version, or never, is stale" do
      assert FirstPartySyncWorker.repository_version_stale?(
               %{last_sync_summary: %{"release_tag" => "v9.9.8"}},
               "v9.9.9"
             )

      assert FirstPartySyncWorker.repository_version_stale?(%{}, "v9.9.9")
      assert FirstPartySyncWorker.repository_version_stale?(nil, "v9.9.9")
    end
  end

  describe "repository_already_synced?/3" do
    test "returns true when the built-in repository cleanly synced the target release and all packages remain present" do
      repository = %{
        builtin: true,
        last_sync_error: nil,
        last_sync_summary: %{
          "status" => "success",
          "release_tag" => "v9.9.9",
          "discovered" => 16,
          "imported" => 16,
          "skipped" => 0,
          "failed_count" => 0
        }
      }

      assert FirstPartySyncWorker.repository_already_synced?(repository, "v9.9.9", 16)
    end

    test "returns false when the previous run recorded an error, a different tag, missing packages, or a custom repository" do
      clean_summary = %{
        "status" => "success",
        "release_tag" => "v9.9.9",
        "discovered" => 16,
        "imported" => 4,
        "skipped" => 12,
        "failed_count" => 0
      }

      refute FirstPartySyncWorker.repository_already_synced?(
               %{builtin: true, last_sync_error: ":rate_limited", last_sync_summary: clean_summary},
               "v9.9.9",
               16
             )

      refute FirstPartySyncWorker.repository_already_synced?(
               %{builtin: true, last_sync_error: nil, last_sync_summary: clean_summary},
               "v9.9.10",
               16
             )

      refute FirstPartySyncWorker.repository_already_synced?(
               %{builtin: true, last_sync_error: nil, last_sync_summary: clean_summary},
               "v9.9.9",
               15
             )

      refute FirstPartySyncWorker.repository_already_synced?(
               %{builtin: false, last_sync_error: nil, last_sync_summary: clean_summary},
               "v9.9.9",
               16
             )
    end
  end

  describe "backoff/1 and terminal_attempt?/2" do
    test "spaces retry attempts across minutes so rate-limit windows can reset" do
      assert FirstPartySyncWorker.backoff(%Job{attempt: 1}) == 120
      assert FirstPartySyncWorker.backoff(%Job{attempt: 2}) == 600
      assert FirstPartySyncWorker.backoff(%Job{attempt: 3}) == 1_800

      assert NativeAddonSyncWorker.backoff(%Job{attempt: 1}) == 120
      assert NativeAddonSyncWorker.backoff(%Job{attempt: 2}) == 600
      assert NativeAddonSyncWorker.backoff(%Job{attempt: 3}) == 1_800
    end

    test "identifies only the final failed Oban attempt as terminal for successor scheduling" do
      refute FirstPartySyncWorker.terminal_attempt?(
               %Job{attempt: 1, max_attempts: 3},
               {:error, :partial_plugin_sync_failure}
             )

      refute FirstPartySyncWorker.terminal_attempt?(
               %Job{attempt: 2, max_attempts: 3},
               {:error, :partial_plugin_sync_failure}
             )

      assert FirstPartySyncWorker.terminal_attempt?(
               %Job{attempt: 3, max_attempts: 3},
               {:error, :partial_plugin_sync_failure}
             )

      refute FirstPartySyncWorker.terminal_attempt?(%Job{attempt: 3, max_attempts: 3}, :ok)

      refute NativeAddonSyncWorker.terminal_attempt?(
               %Job{attempt: 1, max_attempts: 3},
               {:error, :rate_limited}
             )

      assert NativeAddonSyncWorker.terminal_attempt?(
               %Job{attempt: 3, max_attempts: 3},
               {:error, :rate_limited}
             )
    end
  end
end
