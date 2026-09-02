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

  # This is the bug that broke integration_tests_serial_3/4 on the first attempt.
  #
  # DeviceCorrelation.resolve/1 was treated as "returns a canonical uid or nil".
  # It does not: for a uid already shaped like `sr:<...>` it follows the merge
  # chain and falls back to returning the INPUT VERBATIM when the follow finds
  # nothing. That is correct for its own callers -- a pre-merge uid should
  # survive -- but it means a producer that invents an `sr:`-prefixed id gets it
  # handed straight back, and the FK to ocsf_devices then rejects the alert.
  #
  # Losing the alert is far worse than losing its device attribution, so the
  # engine confirms the resolved uid exists before using it.
  describe "the resolver's contract" do
    test "a resolved uid is not guaranteed to exist, so it cannot be trusted directly" do
      source =
        File.read!("lib/serviceradar/event_writer/device_correlation.ex")

      assert source =~ ~r/"sr:" <> _ = uid ->/,
             "the passthrough clause this guards against has moved or changed"

      assert source =~ ~r/follow_canonical_device_id\(uid, actor\) end\) \|\| uid/,
             "resolve/1 no longer falls back to the raw uid; the existence check may be redundant"
    end

    test "the engine confirms the device exists before writing the uid" do
      source =
        File.read!("lib/serviceradar/observability/stateful_alert_engine/alert_lifecycle.ex")

      assert source =~ "existing_device_uid",
             "the resolved uid must be confirmed against inventory before it reaches the FK"

      assert source =~ "Device.get_by_uid",
             "confirmation must be a real inventory lookup"
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
