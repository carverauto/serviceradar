defmodule ServiceRadar.CompositeChecks.VerdictEventWriterTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query

  defp actor, do: SystemActor.system(:composite_check_test)

  defp check do
    %{id: Ash.UUID.generate(), name: "PCI Isolation", slug: "pci-isolation"}
  end

  defp transition(from, to, opts \\ []) do
    %{
      device_uid: Keyword.get(opts, :device_uid, "device-1"),
      check_id: Ash.UUID.generate(),
      from_verdict: from,
      to_verdict: to,
      from_status: Keyword.get(opts, :from_status, :healthy),
      to_status: Keyword.get(opts, :to_status, :down),
      inputs: %{"a" => %{"value" => "available"}, "b" => %{"value" => "available"}}
    }
  end

  defp events do
    OcsfEvent
    |> Ash.Query.filter(log_name == ^VerdictEventWriter.log_name())
    |> Ash.read!(actor: actor())
  end

  test "writes one event per transition" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("isolated_verified", "not_isolated")
             ])

    assert [event] = events()
    assert event.message =~ "not_isolated"
    assert event.unmapped["from_verdict"] == "isolated_verified"
    assert event.unmapped["to_verdict"] == "not_isolated"
    assert event.unmapped["device_uid"] == "device-1"
    assert event.unmapped["check_slug"] == "pci-isolation"
    assert event.unmapped["event_family"] == "composite_check_verdict"
  end

  test "writes one event for each of several transitions" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("isolated_verified", "not_isolated", device_uid: "device-1"),
               transition("isolated_verified", "device_unreachable", device_uid: "device-2")
             ])

    assert length(events()) == 2
  end

  test "an empty transition list writes nothing" do
    assert :ok = VerdictEventWriter.write_transitions(check(), [])
    assert events() == []
  end

  test "a first-time verdict records a nil from_verdict" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition(nil, "isolated_verified", from_status: nil, to_status: :healthy)
             ])

    assert [event] = events()
    assert event.unmapped["from_verdict"] == nil
    assert event.message =~ "from none to isolated_verified"
  end

  test "carries the resolved inputs that produced the change" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("isolated_verified", "not_isolated")
             ])

    assert [event] = events()
    assert event.unmapped["inputs"]["a"]["value"] == "available"
    assert event.unmapped["inputs"]["b"]["value"] == "available"
  end

  test "severity reflects the new status" do
    # A device that should be isolated but is not deserves a severity an
    # operator will actually notice.
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("isolated_verified", "not_isolated", to_status: :down)
             ])

    assert [down_event] = events()
    assert down_event.severity == "High"
  end

  test "recovering to healthy is informational" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("not_isolated", "isolated_verified",
                 from_status: :down,
                 to_status: :healthy
               )
             ])

    assert [event] = events()
    assert event.severity == "Informational"
  end
end
