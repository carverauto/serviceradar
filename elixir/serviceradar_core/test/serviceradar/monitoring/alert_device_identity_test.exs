defmodule ServiceRadar.Monitoring.AlertDeviceIdentityTest do
  @moduledoc """
  Device identity on engine-fired alerts.

  `alerts.device_uid` carries a foreign key to `ocsf_devices(uid)`, so a bad
  value does not produce a mislabelled alert — it fails the insert and the alert
  is lost. In the stateful-engine path that is the worst case of the three
  callers: the error is only logged, the snapshot never receives an `alert_id`,
  and the rule re-fires forever while nobody is paged.

  None of this needs a database to check.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.AlertGenerator

  describe "normalize_device_uid/1" do
    test "passes a real uid through" do
      assert AlertGenerator.normalize_device_uid("dev-abc123") == "dev-abc123"
    end

    test "trims surrounding whitespace" do
      assert AlertGenerator.normalize_device_uid("  dev-abc123  ") == "dev-abc123"
    end

    # An empty string is not a uid. It satisfies is_binary/1, so without this it
    # would reach the column and fail the FK like any other non-device value.
    test "rejects empty and whitespace-only strings" do
      assert AlertGenerator.normalize_device_uid("") == nil
      assert AlertGenerator.normalize_device_uid("   ") == nil
    end

    test "rejects anything that is not a binary" do
      for value <- [nil, 123, :device, %{uid: "x"}, ["x"]] do
        assert AlertGenerator.normalize_device_uid(value) == nil,
               "#{inspect(value)} must not reach the column"
      end
    end
  end

  describe "the alert resource can actually store it" do
    # If :trigger stops accepting device_uid, from_event/2 keeps compiling and
    # keeps passing the value, and it is silently dropped — the whole change
    # becomes inert with nothing failing.
    test ":trigger accepts device_uid" do
      accepted =
        Alert
        |> Info.action(:trigger)
        |> Map.fetch!(:accept)

      assert :device_uid in accepted
    end

    test "device_uid is a real attribute on the resource" do
      assert %{name: :device_uid} = Info.attribute(Alert, :device_uid)
    end

    # Populating the column is not only a labelling change: it is what lets the
    # create-time out-of-service gate see the device at all. That gate reads
    # device_uid off the changeset, so the attribute must remain public.
    test "device_uid is public and writable, so the suppression gate can read it" do
      attribute = Info.attribute(Alert, :device_uid)

      assert attribute.public?, "the out-of-service gate reads this off the changeset input"
      assert attribute.writable?
    end

    # nil is a valid outcome -- a record whose device does not resolve must
    # still produce an alert rather than failing the insert.
    test "device_uid is nullable" do
      assert Info.attribute(Alert, :device_uid).allow_nil?
    end
  end
end
