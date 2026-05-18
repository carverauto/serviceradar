defmodule ServiceRadar.ObjectStore.ReleaseArtifactRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.ObjectStore.ReleaseArtifactRetention

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

  defp release(id, version, object_key) do
    %AgentRelease{
      id: id,
      version: version,
      manifest: %{},
      signature: "signature",
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
