defmodule ServiceRadar.Monitoring.NetperfProfileValidationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfProfile

  describe "NetperfProfile omit_sec < duration_sec validation" do
    test "create changeset rejects omit_sec >= duration_sec before DB submit" do
      cs_equal =
        Ash.Changeset.for_create(NetperfProfile, :create, %{
          name: "bad-equal",
          duration_sec: 3,
          omit_sec: 3
        })

      refute cs_equal.valid?
      assert Enum.any?(cs_equal.errors, &(&1.field == :omit_sec))

      # Default omit_sec is 1, so duration_sec: 1 must fail without explicit omit_sec.
      cs_default_omit =
        Ash.Changeset.for_create(NetperfProfile, :create, %{
          name: "bad-default-omit",
          duration_sec: 1
        })

      refute cs_default_omit.valid?
      assert Enum.any?(cs_default_omit.errors, &(&1.field == :omit_sec))

      cs_valid =
        Ash.Changeset.for_create(NetperfProfile, :create, %{
          name: "good-profile",
          duration_sec: 5,
          omit_sec: 4
        })

      assert cs_valid.valid?
    end

    test "update changeset enforces omit_sec < duration_sec across partial and full updates" do
      existing = %NetperfProfile{
        id: Ecto.UUID.generate(),
        name: "existing",
        protocol: :tcp,
        direction: :upload,
        bandwidth_bps: 50_000_000,
        duration_sec: 10,
        omit_sec: 3,
        parallel: 1,
        packet_length: 1200,
        interval_seconds: 900
      }

      cs_lower_duration = Ash.Changeset.for_update(existing, :update, %{duration_sec: 3})
      refute cs_lower_duration.valid?
      assert Enum.any?(cs_lower_duration.errors, &(&1.field == :omit_sec))

      cs_both_invalid =
        Ash.Changeset.for_update(existing, :update, %{duration_sec: 4, omit_sec: 5})

      refute cs_both_invalid.valid?
      assert Enum.any?(cs_both_invalid.errors, &(&1.field == :omit_sec))

      cs_valid =
        Ash.Changeset.for_update(existing, :update, %{duration_sec: 6, omit_sec: 5})

      assert cs_valid.valid?
    end
  end

  describe "NetperfSpokeSelector agent_uids validation" do
    test "rejects empty and whitespace-only strings in agent_uids" do
      profile_id = Ecto.UUID.generate()

      cs_empty =
        Ash.Changeset.for_create(NetperfPolicy, :create, %{
          name: "bad-empty-uid",
          profile_id: profile_id,
          spoke_selector: %{"agent_uids" => ["agent-1", ""]}
        })

      refute cs_empty.valid?
      assert Enum.any?(cs_empty.errors, &(&1.field == :spoke_selector))

      cs_blank =
        Ash.Changeset.for_create(NetperfPolicy, :create, %{
          name: "bad-blank-uid",
          profile_id: profile_id,
          spoke_selector: %{"agent_uids" => ["   "]}
        })

      refute cs_blank.valid?
      assert Enum.any?(cs_blank.errors, &(&1.field == :spoke_selector))

      cs_valid =
        Ash.Changeset.for_create(NetperfPolicy, :create, %{
          name: "good-uids",
          profile_id: profile_id,
          spoke_selector: %{"agent_uids" => ["agent-1", "agent-2"]}
        })

      assert cs_valid.valid?
    end
  end
end
