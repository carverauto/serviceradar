defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNG.Devices.MergedAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents

  @moduletag :db_free

  test "online, offline and unknown buckets retain explicit status and coverage" do
    availability = %{
      uptime_pct: 50.0,
      total_checks: 2,
      online_checks: 1,
      offline_checks: 1,
      unknown_checks: 1,
      segments: Enum.map([:online, :offline, :unknown], &segment/1)
    }

    document = render(availability)

    assert document
           |> LazyHTML.query("[data-availability-status]")
           |> LazyHTML.attribute("data-availability-status") == ["online", "offline", "unknown"]

    assert document |> LazyHTML.query("#device-availability-percent") |> LazyHTML.text() |> String.trim() ==
             "50.0%"

    assert LazyHTML.text(document) =~ "online among observed buckets"
    assert LazyHTML.text(document) =~ "2 observed of 3 buckets"
  end

  test "unknown-only coverage does not present a healthy percentage" do
    document =
      render(%{
        uptime_pct: nil,
        total_checks: 0,
        unknown_checks: 48,
        segments: List.duplicate(segment(:unknown), 48)
      })

    assert document |> LazyHTML.query("#device-availability-percent") |> LazyHTML.text() |> String.trim() ==
             "—"

    assert document |> LazyHTML.query("[data-availability-status=unknown]") |> LazyHTML.attribute("title") |> length() ==
             48

    assert LazyHTML.text(document) =~ "0 observed of 48 buckets"
  end

  test "the details page marks each agent's role and the record that decided the state" do
    merged =
      %{
        "availability_state" => "available",
        "availability_decided_by" => %{
          "source_kind" => "wifi_map",
          "source_instance" => "controller-01",
          "reporter_agent_id" => "",
          "authority_class" => "managing_controller"
        },
        "availability_changed_at" => "1999-06-15T00:00:00Z",
        "availability_conflict" => true,
        "availability_agents" => %{"up" => 0, "down" => 1, "total" => 1, "blocked_verified" => 1}
      }
      |> MergedAvailability.from_columns()
      |> Map.merge(%{
        expectations: %{"agent-witness" => :reachable, "agent-control" => :blocked},
        evidence: [
          evidence("wifi_map", "controller-01", "up"),
          evidence("inventory_file", "import-01", "down")
        ]
      })

    decision =
      (&AvailabilityComponents.merged_availability_section/1)
      |> render_component(availability: merged)
      |> LazyHTML.from_fragment()

    assert decision |> LazyHTML.query("[data-availability-state]") |> LazyHTML.attribute("data-availability-state") ==
             ["available"]

    assert decision |> LazyHTML.query("[data-availability-conflict]") |> Enum.count() == 1

    decided =
      for row <- LazyHTML.query(decision, "tbody tr"),
          row |> LazyHTML.query("[data-evidence-decided]") |> Enum.count() > 0,
          do: row |> LazyHTML.attribute("data-evidence-source") |> hd()

    assert decided == ["wifi_map"]

    agents =
      (&AvailabilityComponents.agent_availability_section/1)
      |> render_component(
        rows: [
          ledger_row("agent-witness", false, %{}),
          ledger_row("agent-control", false, %{}),
          ledger_row("agent-pinned", true, %{"sweep_reporter_expectation" => "unexpected"}),
          ledger_row("agent-other", true, %{"sweep_reporter_expectation" => "unknown"})
        ],
        device_row: %{"availability_source_agent_id" => "agent-pinned"},
        merged_availability: merged
      )
      |> LazyHTML.from_fragment()

    roles =
      Map.new(LazyHTML.query(agents, "tbody tr"), fn row ->
        [time_id] = row |> LazyHTML.query("time") |> LazyHTML.attribute("id")
        {time_id, row |> LazyHTML.query("[data-agent-role]") |> LazyHTML.attribute("data-agent-role")}
      end)

    assert roles == %{
             "device-agent-availability-agent-witness-checked-at" => ["witness"],
             "device-agent-availability-agent-control-checked-at" => ["negative control"],
             "device-agent-availability-agent-pinned-checked-at" => ["pinned"],
             "device-agent-availability-agent-other-checked-at" => ["ineligible"]
           }
  end

  defp evidence(kind, instance, state) do
    %{
      source_kind: kind,
      source_instance: instance,
      reporter_agent_id: "",
      authority_class: "managing_controller",
      state: state,
      observed_at: ~U[1999-06-15 00:00:00Z],
      expires_at: ~U[1999-06-15 03:00:00Z],
      confirmations: 1,
      reporter_eligible: true
    }
  end

  defp ledger_row(agent_id, available?, metadata) do
    %{
      agent_id: agent_id,
      agent_name: nil,
      is_available: available?,
      checked_at: ~U[1999-06-15 00:00:00Z],
      response_time_ms: nil,
      open_ports: [],
      sweep_modes_results: %{},
      metadata: metadata
    }
  end

  defp render(availability) do
    (&AvailabilityComponents.availability_section/1)
    |> render_component(availability: availability)
    |> LazyHTML.from_fragment()
  end

  defp segment(status) do
    %{status: status, width: 1.0, timestamp: "1999-06-15T00:00:00Z", title: "Invented #{status} bucket"}
  end
end
