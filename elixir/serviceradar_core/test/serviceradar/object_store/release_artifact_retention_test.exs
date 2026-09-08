defmodule ServiceRadar.ObjectStore.ReleaseArtifactRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.ObjectStore.ReleaseArtifactRetention

  describe "retained_release_ids/2" do
    test "keeps only the most recently imported release by default" do
      latest_upstream =
        release(
          "release-latest-upstream",
          "1.2.99",
          "agent-releases/1.2.99/linux-amd64.tar.zst",
          updated_at: ~U[2026-06-09 10:00:00Z],
          inserted_at: ~U[2026-06-09 10:00:00Z],
          published_at: ~U[2026-06-09 09:00:00Z]
        )

      older_imported_later =
        release(
          "release-older-imported-later",
          "1.2.80",
          "agent-releases/1.2.80/linux-amd64.tar.zst",
          updated_at: ~U[2026-06-09 11:00:00Z],
          inserted_at: ~U[2026-06-09 11:00:00Z],
          published_at: ~U[2026-05-01 09:00:00Z]
        )

      assert ReleaseArtifactRetention.retained_release_ids(
               [latest_upstream, older_imported_later],
               1
             ) == MapSet.new(["release-older-imported-later"])
    end

    test "keeps no unreferenced imported releases when configured for zero" do
      release =
        release(
          "release-current",
          "1.2.99",
          "agent-releases/1.2.99/linux-amd64.tar.zst",
          updated_at: ~U[2026-06-09 10:00:00Z]
        )

      assert ReleaseArtifactRetention.retained_release_ids([release], 0) == MapSet.new()
    end
  end

  describe "plan/3" do
    test "protects release artifacts referenced by active rollout or target state" do
      referenced_release =
        release(
          "release-referenced",
          "1.2.66",
          "agent-releases/1.2.66/linux-amd64.tar.zst"
        )

      superseded_release =
        release(
          "release-superseded",
          "1.2.65",
          "agent-releases/1.2.65/linux-amd64.tar.zst"
        )

      plan =
        ReleaseArtifactRetention.plan(
          [referenced_release, superseded_release],
          MapSet.new(["release-referenced"]),
          [
            object("agent-releases/1.2.66/linux-amd64.tar.zst"),
            object("agent-releases/1.2.65/linux-amd64.tar.zst")
          ]
        )

      assert [%{key: "agent-releases/1.2.66/linux-amd64.tar.zst", reason: :referenced_release}] =
               plan.protected

      assert [
               %{
                 key: "agent-releases/1.2.65/linux-amd64.tar.zst",
                 reason: :retained_release_count_exceeded
               }
             ] = plan.eligible
    end

    test "deletes orphaned objects not present in release metadata" do
      plan =
        ReleaseArtifactRetention.plan(
          [
            release(
              "release-current",
              "1.2.66",
              "agent-releases/1.2.66/linux-amd64.tar.zst"
            )
          ],
          MapSet.new(["release-current"]),
          [
            object("agent-releases/1.2.66/linux-amd64.tar.zst"),
            object("agent-releases/orphan/linux-amd64.tar.zst")
          ]
        )

      assert Enum.any?(plan.protected, &(&1.key == "agent-releases/1.2.66/linux-amd64.tar.zst"))

      assert [
               %{
                 key: "agent-releases/orphan/linux-amd64.tar.zst",
                 release: nil,
                 reason: :orphaned_object
               }
             ] = plan.eligible
    end
  end

  defp release(id, version, object_key, opts \\ []) do
    %AgentRelease{
      id: id,
      version: version,
      manifest: %{},
      signature: "signature",
      inserted_at: Keyword.get(opts, :inserted_at),
      updated_at: Keyword.get(opts, :updated_at),
      published_at: Keyword.get(opts, :published_at),
      metadata: %{
        "storage" => %{
          "artifacts" => [
            %{"object_key" => object_key}
          ]
        }
      }
    }
  end

  defp object(key), do: %{metadata: %{key: key}}
end
