defmodule ServiceRadar.Integrations.CompositeNorthboundValuesTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Integrations.CompositeNorthboundValues
  alias ServiceRadar.Inventory.Device

  defp actor, do: SystemActor.system(:composite_northbound_test)

  defp device!(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "nb-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp check!(name) do
    CompositeCheck
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, scope_query: "in:devices"},
      actor: actor()
    )
    |> Ash.create!()
  end

  defp enable!(check) do
    CompositeCheckInput
    |> Ash.Changeset.for_create(
      :create,
      %{
        check_id: check.id,
        key: "witness",
        label: "witness",
        position: 0,
        kind: :vantage_point,
        expected: "available",
        config: %{"agent_id" => "witness"}
      },
      actor: actor()
    )
    |> Ash.create!()

    check
    |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
    |> Ash.update!()
  end

  defp result!(device_uid, check, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: now,
        changed_at: now
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  defp export(check, form),
    do: %{check_slug: check.slug, value_form: form, custom_field: "sr_isolation"}

  describe "for_devices/3" do
    test "returns the verdict slug per device in verdict form" do
      a = device!("nb-verdict-a")
      b = device!("nb-verdict-b")
      check = "Verdict Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, check, "isolated_verified", :healthy)
      result!(b.uid, check, "not_isolated", :down)

      values =
        CompositeNorthboundValues.for_devices(export(check, :verdict), [a.uid, b.uid],
          actor: actor()
        )

      assert values == %{a.uid => "isolated_verified", b.uid => "not_isolated"}
    end

    test "returns the status enum in status form" do
      a = device!("nb-status-a")
      check = "Status Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, check, "isolated_verified", :healthy)

      values =
        CompositeNorthboundValues.for_devices(export(check, :status), [a.uid], actor: actor())

      # A string, not an atom: this is what goes on the wire.
      assert values == %{a.uid => "healthy"}
    end

    test "a device with no result is absent rather than mapped to a placeholder" do
      a = device!("nb-absent-a")
      check = "Absent Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, check, "isolated_verified", :healthy)

      values =
        CompositeNorthboundValues.for_devices(
          export(check, :verdict),
          [a.uid, "nb-absent-never-evaluated"],
          actor: actor()
        )

      # Absence is the representation. A nil value would put the obligation to
      # omit on every caller instead of making it the default.
      assert Map.keys(values) == [a.uid]
      refute Map.has_key?(values, "nb-absent-never-evaluated")
    end

    test "a device evaluated by a different check is not included" do
      a = device!("nb-other-a")
      exported = "Exported #{System.unique_integer([:positive])}" |> check!() |> enable!()
      other = "Other #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, other, "not_isolated", :down)

      assert CompositeNorthboundValues.for_devices(export(exported, :verdict), [a.uid],
               actor: actor()
             ) == %{}
    end

    test "an unknown slug yields no values rather than every device" do
      a = device!("nb-unknown-a")

      unknown = %{check_slug: "no-such-check", value_form: :verdict, custom_field: "f"}

      assert CompositeNorthboundValues.for_devices(unknown, [a.uid], actor: actor()) == %{}
    end

    test "a draft check yields no values" do
      a = device!("nb-draft-a")
      check = check!("Draft Export #{System.unique_integer([:positive])}")

      result!(a.uid, check, "isolated_verified", :healthy)

      # Nothing maintains a draft's results on a schedule, so exporting them
      # would publish a value that silently stops moving.
      assert check.state == :draft

      assert CompositeNorthboundValues.for_devices(export(check, :verdict), [a.uid],
               actor: actor()
             ) == %{}
    end

    test "a disabled check yields no values" do
      a = device!("nb-disabled-a")
      check = "Disabled Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, check, "isolated_verified", :healthy)

      disabled =
        check
        |> Ash.Changeset.for_update(:set_state, %{state: :disabled}, actor: actor())
        |> Ash.update!()

      assert CompositeNorthboundValues.for_devices(export(disabled, :verdict), [a.uid],
               actor: actor()
             ) == %{}
    end

    test "no export configured yields no values" do
      assert CompositeNorthboundValues.for_devices(nil, ["nb-any"], actor: actor()) == %{}
    end

    test "an empty device list yields no values" do
      check = "Empty Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      assert CompositeNorthboundValues.for_devices(export(check, :verdict), [], actor: actor()) ==
               %{}
    end

    test "duplicate device uids collapse to one entry" do
      a = device!("nb-dupe-a")
      check = "Dupe Export #{System.unique_integer([:positive])}" |> check!() |> enable!()

      result!(a.uid, check, "isolated_verified", :healthy)

      values =
        CompositeNorthboundValues.for_devices(export(check, :verdict), [a.uid, a.uid, a.uid],
          actor: actor()
        )

      assert values == %{a.uid => "isolated_verified"}
    end
  end
end
