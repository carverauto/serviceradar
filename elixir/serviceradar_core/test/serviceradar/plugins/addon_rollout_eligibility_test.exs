defmodule ServiceRadar.Plugins.AddonRolloutEligibilityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility

  @moduletag :db_free

  test "selects the newest stable trusted candidate within the capability ceiling" do
    current = package(version: "1.0.0")
    older = package(version: "1.1.0")
    newest = package(version: "1.2.0")
    prerelease = package(version: "2.0.0-beta.1")

    assert {:ok, ^newest} =
             Eligibility.latest_candidate(current, [prerelease, older, newest], source())
  end

  test "fails closed when the only newer candidate expands privileges" do
    current = package(version: "1.0.0")
    privileged = package(version: "1.1.0", approved_capabilities: ["network", "root"])

    assert {:blocked, :capability_ceiling_exceeded, ^privileged} =
             Eligibility.latest_candidate(current, [privileged], source())
  end

  test "does not select staged, unverified, mutable, or already blocked candidates" do
    current = package(version: "1.0.0")
    staged = package(version: "1.4.0", status: :staged)
    unverified = package(version: "1.3.0", verification_status: "failed")
    mutable = package(version: "1.2.0", source_oci_digest: nil)
    blocked = package(version: "1.1.0")

    assert :none =
             Eligibility.latest_candidate(
               current,
               [staged, unverified, mutable, blocked],
               source(),
               blocked_candidate_ids: [blocked.id]
             )
  end

  test "permits an explicitly tracked verified third-party origin without crossing repositories" do
    current =
      package(
        version: "1.0.0",
        source_type: :imported,
        source_oci_ref: "registry.example/vendor/netprobe:v1.0.0"
      )

    candidate =
      package(
        version: "1.1.0",
        source_type: :imported,
        source_oci_ref: "registry.example/vendor/netprobe:v1.1.0"
      )

    different_origin =
      package(
        version: "2.0.0",
        source_type: :imported,
        source_oci_ref: "registry.example/other/netprobe:v2.0.0"
      )

    assert {:ok, ^candidate} =
             Eligibility.latest_candidate(current, [different_origin, candidate], source())
  end

  test "classifies fresh compatible agents separately from unavailable and incompatible agents" do
    now = ~U[2026-07-18 17:00:00Z]
    candidate = package(version: "1.1.0")

    assert {:eligible, nil} = Eligibility.classify_target(candidate, agent(now), now)

    assert {:unavailable, "agent_unavailable_or_stale"} =
             Eligibility.classify_target(candidate, agent(now, status: :disconnected), now)

    assert {:incompatible, "missing_platform_artifact"} =
             Eligibility.classify_target(candidate, agent(now, arch: "arm64"), now)
  end

  test "uses supervision-specific readiness instead of requiring every add-on to be active" do
    timer = package(supervision: :systemd_timer)
    helper = package(supervision: :ephemeral_helper)
    service = package(supervision: :systemd_service)

    refute Eligibility.supervision_ready?(service, %{state: "ready", active: false})
    assert Eligibility.supervision_ready?(timer, %{state: "waiting", active: false})
    assert Eligibility.supervision_ready?(helper, %{state: "staged", active: false})
  end

  defp source do
    %{
      release_channel: "stable",
      capability_ceiling: ["network"],
      rollout_policy: %{}
    }
  end

  defp package(overrides) do
    values =
      Keyword.merge(
        [
          id: Ecto.UUID.generate(),
          addon_id: "netprobe",
          name: "Netprobe",
          version: "1.0.0",
          status: :approved,
          source_type: :first_party,
          source_oci_ref: "registry.example/netprobe:v1",
          source_oci_digest: "sha256:trusted",
          verification_status: "verified",
          verification_error: nil,
          approved_capabilities: ["network"],
          capabilities: ["network"],
          delivery: :pushed_artifact,
          supervision: :agent_sidecar,
          requires: %{"platforms" => ["linux"], "base_agent" => ">= 1.2.0"},
          artifacts: %{
            "linux/amd64" => %{"object_key" => "addons/netprobe", "sha256" => "abc"}
          }
        ],
        overrides
      )

    struct!(AddonPackage, values)
  end

  defp agent(now, overrides \\ []) do
    %{
      uid: "agent-1",
      version: "1.4.23",
      capabilities: [],
      status: Keyword.get(overrides, :status, :connected),
      is_healthy: true,
      last_seen_time: now,
      metadata: %{
        "os" => Keyword.get(overrides, :os, "linux"),
        "arch" => Keyword.get(overrides, :arch, "amd64")
      }
    }
  end
end
