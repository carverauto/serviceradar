defmodule ServiceRadar.Inventory.AvailabilitySourceProfileMaterializerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AvailabilitySourceProfile
  alias ServiceRadar.Inventory.AvailabilitySourceProfileMaterializer
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  defmodule FakeRunner do
    @moduledoc false

    def query_page(query, _opts) do
      rows =
        :availability_source_profile_rows
        |> Process.get(%{})
        |> Map.get(query, [])

      {:ok, %{rows: rows, next_cursor: nil}}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:availability_source_profile_test)
    {:ok, actor: actor}
  end

  test "materialize applies profile precedence and preserves per-device overrides", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_a = create_device!(actor, "profile-a-#{unique}", "10.50.#{rem(unique, 200)}.1")
    device_b = create_device!(actor, "profile-b-#{unique}", "10.50.#{rem(unique, 200)}.2")
    device_c = create_device!(actor, "profile-c-#{unique}", "10.50.#{rem(unique, 200)}.3")

    device_b =
      update_source!(device_b, actor, %{
        availability_source_agent_id: "agent-manual",
        availability_source_profile_id: nil
      })

    low_profile =
      create_profile!(actor, %{
        name: "Plant profile #{unique}",
        srql_query: "in:devices tags.segment:plant",
        agent_id: "agent-low",
        priority: 10
      })

    high_profile =
      create_profile!(actor, %{
        name: "Core profile #{unique}",
        srql_query: "in:devices tags.role:core",
        agent_id: "agent-high",
        priority: 20
      })

    Process.put(:availability_source_profile_rows, %{
      high_profile.srql_query => [%{"uid" => device_a.uid}, %{"uid" => device_b.uid}],
      low_profile.srql_query => [%{"uid" => device_a.uid}, %{"uid" => device_c.uid}]
    })

    assert {:ok, summary} =
             AvailabilitySourceProfileMaterializer.materialize(
               actor: actor,
               runner: FakeRunner
             )

    assert summary.matched_devices == 3
    assert summary.applied_devices == 2

    assert refreshed(device_a, actor).availability_source_agent_id == "agent-high"
    assert refreshed(device_a, actor).availability_source_profile_id == high_profile.id

    assert refreshed(device_b, actor).availability_source_agent_id == "agent-manual"
    assert is_nil(refreshed(device_b, actor).availability_source_profile_id)

    assert refreshed(device_c, actor).availability_source_agent_id == "agent-low"
    assert refreshed(device_c, actor).availability_source_profile_id == low_profile.id

    assert refreshed_profile(high_profile, actor).match_count == 2
    assert refreshed_profile(high_profile, actor).applied_count == 1
    assert refreshed_profile(low_profile, actor).match_count == 2
    assert refreshed_profile(low_profile, actor).applied_count == 1
  after
    Process.delete(:availability_source_profile_rows)
  end

  test "materialize clears stale profile-derived assignments", %{actor: actor} do
    unique = System.unique_integer([:positive])

    disabled_profile =
      create_profile!(actor, %{
        name: "Disabled profile #{unique}",
        srql_query: "in:devices hostname:disabled-#{unique}",
        agent_id: "agent-disabled",
        enabled: false
      })

    device =
      actor
      |> create_device!("profile-stale-#{unique}", "10.51.#{rem(unique, 200)}.1")
      |> update_source!(actor, %{
        availability_source_agent_id: "agent-disabled",
        availability_source_profile_id: disabled_profile.id
      })

    assert {:ok, summary} =
             AvailabilitySourceProfileMaterializer.materialize(
               actor: actor,
               runner: FakeRunner
             )

    assert summary.cleared_devices >= 1
    assert is_nil(refreshed(device, actor).availability_source_agent_id)
    assert is_nil(refreshed(device, actor).availability_source_profile_id)
  end

  test "preview_scope normalizes device SRQL and returns bounded rows" do
    Process.put(:availability_source_profile_rows, %{
      "in:devices tags.segment:plant" => [%{"uid" => "device-a"}, %{"uid" => "device-b"}]
    })

    assert {:ok, preview} =
             AvailabilitySourceProfileMaterializer.preview_scope("tags.segment:plant",
               runner: FakeRunner
             )

    assert preview.query == "in:devices tags.segment:plant"
    assert preview.total_count == 2
    assert Enum.map(preview.rows, & &1["uid"]) == ["device-a", "device-b"]
  after
    Process.delete(:availability_source_profile_rows)
  end

  defp create_device!(actor, hostname, ip) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: "sr:#{Ecto.UUID.generate()}",
        hostname: hostname,
        ip: ip,
        type_id: 1,
        type: "Server",
        is_available: true,
        metadata: %{},
        tags: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_profile!(actor, attrs) do
    attrs =
      Map.merge(
        %{
          description: nil,
          enabled: true,
          priority: 100,
          metadata: %{}
        },
        attrs
      )

    AvailabilitySourceProfile
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp update_source!(device, actor, attrs) do
    device
    |> Ash.Changeset.for_update(:set_availability_source, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp refreshed(device, actor) do
    Device.get_by_uid!(device.uid, false, actor: actor)
  end

  defp refreshed_profile(profile, actor) do
    AvailabilitySourceProfile.get_by_id!(profile.id, actor: actor)
  end
end
