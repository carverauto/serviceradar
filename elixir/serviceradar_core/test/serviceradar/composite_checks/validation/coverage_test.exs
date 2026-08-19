defmodule ServiceRadar.CompositeChecks.Validation.CoverageTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Validation.Coverage
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  defp actor, do: SystemActor.system(:validation_coverage_test)

  defp unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"
  end

  defp create_device!(ip) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "cov-#{System.unique_integer([:positive])}",
        ip: ip
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp create_profile!(attrs) do
    SweepProfile
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: "profile-#{System.unique_integer([:positive])}",
          ports: [22, 80, 443, 8080],
          sweep_modes: ["icmp", "tcp", "arp"]
        },
        attrs
      ),
      actor: actor()
    )
    |> Ash.create!()
  end

  defp create_group!(attrs) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: "group-#{System.unique_integer([:positive])}",
          partition: "default",
          interval: "1h"
        },
        attrs
      ),
      actor: actor()
    )
    |> Ash.create!()
  end

  test "a device matching in:devices inherits the group's compiled profile settings" do
    ip = unique_ip()
    device = create_device!(ip)
    profile = create_profile!(%{ports: [22, 80, 443, 8080], sweep_modes: ["icmp", "tcp", "arp"]})

    create_group!(%{
      agent_id: "agent-alma-test01",
      target_query: "in:devices",
      profile_id: profile.id
    })

    assert {:ok, settings} =
             Coverage.cover(device.uid, ip, "default", "agent-alma-test01")

    assert "icmp" in settings.modes
    assert "tcp" in settings.modes
    refute "arp" in settings.modes
    assert settings.ports == [22, 80, 443, 8080]
    assert settings.profile_ids == [profile.id]
  end

  test "a host outside the group's SRQL is uncovered" do
    ip = unique_ip()
    device = create_device!(ip)
    profile = create_profile!(%{})

    create_group!(%{
      agent_id: "k8s-agent",
      target_query: "in:devices ip:172.16.0.0/12",
      profile_id: profile.id
    })

    assert {:error, :uncovered} =
             Coverage.cover(device.uid, ip, "default", "k8s-agent")
  end

  test "group port override beats the profile" do
    ip = unique_ip()
    device = create_device!(ip)
    profile = create_profile!(%{ports: [22, 80, 443, 8080], sweep_modes: ["icmp", "tcp"]})

    create_group!(%{
      agent_id: "agent-alma-test01",
      target_query: "in:devices",
      profile_id: profile.id,
      ports: [443]
    })

    assert {:ok, settings} =
             Coverage.cover(device.uid, ip, "default", "agent-alma-test01")

    assert settings.ports == [443]
  end

  test "static_targets CIDR covers the device without SRQL" do
    ip = unique_ip()
    device = create_device!(ip)
    profile = create_profile!(%{ports: [22], sweep_modes: ["icmp"]})

    create_group!(%{
      agent_id: "agent-x",
      static_targets: ["10.0.0.0/8"],
      profile_id: profile.id
    })

    assert {:ok, settings} = Coverage.cover(device.uid, ip, "default", "agent-x")
    assert settings.ports == [22]
    assert settings.modes == ["icmp"]
  end
end
