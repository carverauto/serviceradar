defmodule ServiceRadar.Automation.Northbound.EventHandlerRunnerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Northbound.EventHandlerRunner

  @actor %{id: "system:test", email: "test@system.serviceradar", role: :system}

  test "automatic handlers render targets and inputs before dispatch" do
    handler = handler(%{approval_mode: :automatic})

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               create_and_dispatch: fn attrs, opts ->
                 assert opts[:actor] == @actor
                 assert attrs.descriptor_id == "018f2fd1-f0ff-7cf0-9dc0-000000000001"
                 assert attrs.event_handler_id == "018f2fd1-f0ff-7cf0-9dc0-000000000002"
                 assert attrs.originating_event_id == "event-1"
                 assert attrs.source == :event_handler

                 assert attrs.targets == [
                          %{
                            "kind" => "interface",
                            "device_uid" => "sr:device-1",
                            "interface_uid" => "if-1"
                          }
                        ]

                 assert attrs.input_values == %{
                          "reason" => "RADIUS auth failure",
                          "severity" => "High"
                        }

                 {:ok, %{id: "inv-1", state: :dispatching}}
               end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :dispatched
    assert result.invocation_id == "inv-1"
  end

  test "target resolver normalizes lists and infers device interface and event kinds" do
    parent = self()

    handler =
      handler(%{
        approval_mode: :automatic,
        target_resolver: %{
          "targets" => [
            %{"device_uid" => "{{ metadata.device_uid }}"},
            %{
              "device_uid" => "{{ metadata.device_uid }}",
              "interface_uid" => "{{ metadata.interface_uid }}"
            },
            %{"event_id" => "{{ event.id }}"},
            %{"kind" => ""}
          ]
        }
      })

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               create_and_dispatch: fn attrs, _opts ->
                 send(parent, {:target_attrs, attrs})
                 {:ok, %{id: "inv-targets", state: :dispatching}}
               end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :dispatched
    assert result.invocation_id == "inv-targets"

    assert_received {:target_attrs, attrs}

    assert attrs.targets == [
             %{"kind" => "device", "device_uid" => "sr:device-1"},
             %{
               "kind" => "interface",
               "device_uid" => "sr:device-1",
               "interface_uid" => "if-1"
             },
             %{"kind" => "event", "event_id" => "event-1"}
           ]
  end

  test "manual handlers create a pending approval invocation without dispatching" do
    handler = handler(%{approval_mode: :manual})

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               create_invocation: fn attrs, _opts ->
                 assert attrs.metadata["approval_required"] == true
                 {:ok, %{id: "inv-approval", state: :pending}}
               end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :pending_approval
    assert result.invocation_id == "inv-approval"
  end

  test "dry-run handlers create and suppress an invocation" do
    handler = handler(%{approval_mode: :dry_run})

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               create_invocation: fn attrs, _opts ->
                 assert attrs.metadata["dry_run"] == true
                 {:ok, %{id: "inv-dry-run", state: :pending}}
               end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :dry_run
    assert result.invocation_id == "inv-dry-run"
  end

  test "cooldown suppresses recently triggered handlers" do
    handler =
      handler(%{
        approval_mode: :automatic,
        cooldown_seconds: 300,
        last_triggered_at: ~U[2026-05-16 05:00:00Z]
      })

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               now: ~U[2026-05-16 05:01:00Z],
               create_and_dispatch: fn _attrs, _opts -> flunk("should not dispatch") end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :suppressed
    assert result.reason == :cooldown
  end

  test "non-matching handlers are ignored" do
    handler =
      handler(%{
        match_expression: %{"field" => "event.severity", "equals" => "Critical"}
      })

    assert {:ok, [result]} =
             EventHandlerRunner.handle_event(event(),
               handlers: [handler],
               actor: @actor,
               create_and_dispatch: fn _attrs, _opts -> flunk("should not dispatch") end,
               emit_event: fn _attrs, _actor -> :ok end
             )

    assert result.status == :ignored
    assert result.reason == :not_matched
  end

  defp event do
    %{
      id: "event-1",
      severity: "High",
      message: "RADIUS auth failure",
      metadata: %{
        device_uid: "sr:device-1",
        interface_uid: "if-1"
      }
    }
  end

  defp handler(overrides) do
    Map.merge(
      %{
        id: "018f2fd1-f0ff-7cf0-9dc0-000000000002",
        name: "Disable port on RADIUS auth failure",
        descriptor_id: "018f2fd1-f0ff-7cf0-9dc0-000000000001",
        match_expression: %{
          "all" => [
            %{"field" => "event.severity", "in" => ["High", "Critical"]},
            %{"field" => "event.message", "contains" => "RADIUS"}
          ]
        },
        target_resolver: %{
          "kind" => "interface",
          "device_uid" => "{{ metadata.device_uid }}",
          "interface_uid" => "{{ metadata.interface_uid }}"
        },
        input_template: %{
          "reason" => "{{ event.message }}",
          "severity" => "{{ event.severity }}"
        },
        dedupe_key_template: "{{ event.id }}",
        cooldown_seconds: 0,
        approval_mode: :automatic,
        metadata: %{}
      },
      overrides
    )
  end
end
