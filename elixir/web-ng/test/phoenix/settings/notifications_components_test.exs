defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.ComponentsTest do
  @moduledoc """
  DB-free render tests for the notification settings surface.

  Two of these are the requirements themselves rather than incidental coverage:
  a suppressed delivery must be DISPLAYED with its reason (not omitted), and the
  edge-only escalation warning must appear for the configuration that triggers
  it, on the policy row rather than only inside the editor.
  """

  # async: false because the (globally named) Endpoint is started so `~p`
  # verified routes resolve without the full application and its database.
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Components
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafety

  @moduletag :db_free

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    :ok
  end

  defp delivery(attrs) do
    Map.merge(
      %{
        id: "018f7a10-0000-7000-8000-00000000000a",
        state: :sent,
        suppression_reason: nil,
        occurrence_count: 1,
        last_evaluated_at: nil,
        is_test: false,
        alert_id: "018f7a10-0000-7000-8000-00000000000b",
        alert_snapshot: %{"title" => "Core switch down", "severity" => "critical"},
        channel_id: "chan-1",
        route_id: nil,
        step_number: 1,
        dedupe_key: "rule:1|device=sw01",
        attempt_count: 1,
        max_attempts: 3,
        next_attempt_at: nil,
        error_class: nil,
        error_message: nil,
        external_correlation_id: nil,
        command_id: nil,
        rendered_payload_digest: "sha256:abc",
        result_summary: %{},
        payload_format: :slack_blocks,
        provider_version: 3,
        execution_route: :control_plane,
        agent_uid: nil,
        originating_delivery_id: nil,
        queued_at: ~U[2026-08-09 12:00:00.000000Z],
        started_at: nil,
        finished_at: nil
      },
      attrs
    )
  end

  defp channel_index do
    %{
      "chan-1" => %{
        id: "chan-1",
        name: "Slack #noc",
        enabled: true,
        execution_route: :control_plane,
        partition_id: nil,
        agent_uid: nil,
        fail_closed: false,
        fallback_channel_id: nil
      }
    }
  end

  defp render_deliveries(rows) do
    assigns = %{
      streams: %{deliveries: Enum.with_index(rows, &{"deliveries-#{&2}", &1})},
      filters: DeliveryFilters.empty(),
      channel_index: channel_index()
    }

    rendered_to_string(~H"""
    <Components.deliveries_tab
      streams={@streams}
      filters={@filters}
      channel_index={@channel_index}
      selected={nil}
      limit={100}
      loading={false}
    />
    """)
  end

  describe "delivery log" do
    test "a suppressed delivery is displayed with its reason and its explanation" do
      html =
        render_deliveries([
          delivery(%{
            state: :suppressed,
            suppression_reason: :silence,
            occurrence_count: 42,
            last_evaluated_at: ~U[2026-08-09 12:30:00.000000Z]
          })
        ])

      assert html =~ "Suppressed"
      assert html =~ "Silence"
      assert html =~ "An active maintenance window matched this alert."
      assert html =~ "recorded 42 times"
      assert html =~ "data-suppression-reason"
    end

    test "an unrouted alert is visible with the no-matching-route reason" do
      html =
        render_deliveries([
          delivery(%{state: :suppressed, suppression_reason: :no_matching_route, channel_id: nil})
        ])

      assert html =~ "No matching route"
      assert html =~ "matched zero enabled routes"
    end

    test "every suppression reason is offerable as a filter, including no_matching_route" do
      html = render_deliveries([])

      for label <- [
            "Device out of service",
            "Silence",
            "Schedule",
            "Snoozed",
            "Throttled",
            "Acknowledged",
            "Channel disabled",
            "Dependency",
            "No matching route"
          ] do
        assert html =~ label
      end
    end

    test "a test delivery is visually distinguished" do
      html = render_deliveries([delivery(%{is_test: true})])

      assert html =~ "Test send"
    end

    test "a retrying delivery reads as pending with its bound, not as failed" do
      html =
        render_deliveries([
          delivery(%{
            state: :pending,
            attempt_count: 2,
            max_attempts: 5,
            error_class: "http_503",
            next_attempt_at: ~U[2026-08-09 12:05:00.000000Z]
          })
        ])

      assert html =~ "Pending"
      assert html =~ "2 of 5"
      assert html =~ "http_503"
      refute html =~ ">Failed<"
    end

    test "a failover row is labelled rather than presented as an independent dispatch" do
      html =
        render_deliveries([
          delivery(%{originating_delivery_id: "018f7a10-0000-7000-8000-00000000000c"})
        ])

      assert html =~ "data-failover"
      assert html =~ "Failover"
    end

    test "a delivery whose alert was retention-deleted still renders from its snapshot" do
      html =
        render_deliveries([
          delivery(%{
            alert_id: nil,
            alert_snapshot: %{"title" => "Site A unreachable", "severity" => "critical"}
          })
        ])

      assert html =~ "Site A unreachable"
      assert html =~ "alert no longer available"
    end

    test "the detail pane shows a redacted summary and the digest, never the wire payload" do
      selected = %{
        delivery:
          delivery(%{
            state: :suppressed,
            suppression_reason: :silence,
            rendered_payload_digest: "sha256:deadbeef",
            result_summary: %{
              "status" => 200,
              "suppression" => %{
                "reason" => "silence",
                "detail" => %{"silence_id" => "018f7a10-0000-7000-8000-0000000000ff"}
              }
            }
          }),
        chain: %{origin: nil, successors: []}
      }

      assigns = %{selected: selected, channel_index: channel_index()}

      html =
        rendered_to_string(~H"""
        <Components.delivery_detail selected={@selected} channel_index={@channel_index} />
        """)

      assert html =~ "Redacted payload summary"
      assert html =~ "sha256:deadbeef"
      assert html =~ "The wire payload is never displayed"
      # The suppressed row points at the silence that withheld it.
      assert html =~ "Open the silence"
      assert html =~ "018f7a10-0000-7000-8000-0000000000ff"
      # Nested provider structures are never dumped into the page.
      refute html =~ "suppression&quot;: {"
    end

    test "untrusted alert titles are escaped, never rendered as markup" do
      html =
        render_deliveries([
          delivery(%{alert_snapshot: %{"title" => "<script>alert(1)</script>", "severity" => "high"}})
        ])

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "edge-route escalation warning" do
    defp edge_policy_assigns do
      channels = %{
        "edge-1" => %{
          id: "edge-1",
          name: "Site A agent page",
          enabled: true,
          execution_route: :edge_agent,
          partition_id: "site-a",
          agent_uid: "agent-a",
          fail_closed: false,
          fallback_channel_id: nil
        }
      }

      policy = %{
        id: "policy-1",
        name: "Site A ladder",
        repeat_count: 1,
        repeat_interval_seconds: 300,
        resolve_notifies: true,
        steps: [
          %{
            step_number: 1,
            delay_seconds: 0,
            condition: :always,
            step_channels: [%{channel_id: "edge-1"}]
          }
        ]
      }

      warning = EdgeRouteSafety.evaluate([["edge-1"]], channels)

      %{
        policies: [policy],
        channel_index: channels,
        policy_warnings: %{"policy-1" => warning}
      }
    end

    test "the warning appears on the policy row, outside the editor" do
      assigns = edge_policy_assigns()

      html =
        rendered_to_string(~H"""
        <Components.policies_panel
          policies={@policies}
          can_manage={true}
          channel_index={@channel_index}
          policy_warnings={@policy_warnings}
        />
        """)

      assert html =~ "data-edge-route-warning"
      assert html =~ "cannot deliver a site-down page"
      assert html =~ "site-a"
      assert html =~ "control-plane"
    end

    test "fan-out renders as one step holding a set of channels" do
      channels = %{
        "slack" => %{
          id: "slack",
          name: "Slack #noc",
          enabled: true,
          execution_route: :control_plane,
          partition_id: nil,
          agent_uid: nil,
          fail_closed: false,
          fallback_channel_id: nil
        },
        "email" => %{
          id: "email",
          name: "Email noc@",
          enabled: true,
          execution_route: :control_plane,
          partition_id: nil,
          agent_uid: nil,
          fail_closed: false,
          fallback_channel_id: nil
        }
      }

      assigns = %{
        policies: [
          %{
            id: "policy-2",
            name: "Standard ladder",
            repeat_count: 0,
            repeat_interval_seconds: 300,
            resolve_notifies: true,
            steps: [
              %{
                step_number: 1,
                delay_seconds: 0,
                condition: :always,
                step_channels: [%{channel_id: "slack"}, %{channel_id: "email"}]
              },
              %{
                step_number: 2,
                delay_seconds: 300,
                condition: :if_unacknowledged,
                step_channels: [%{channel_id: "slack"}]
              }
            ]
          }
        ],
        channel_index: channels
      }

      html =
        rendered_to_string(~H"""
        <Components.policies_panel
          policies={@policies}
          can_manage={false}
          channel_index={@channel_index}
          policy_warnings={%{}}
        />
        """)

      assert html =~ "t+0s"
      assert html =~ "t+5m"
      assert html =~ "Slack #noc"
      assert html =~ "Email noc@"
      assert html =~ "if unacknowledged"
      refute html =~ "data-edge-route-warning"
    end

    test "a step referencing a disabled channel is flagged with the consequence" do
      channels = %{
        "slack" => %{
          id: "slack",
          name: "Slack #noc",
          enabled: false,
          execution_route: :control_plane,
          partition_id: nil,
          agent_uid: nil,
          fail_closed: false,
          fallback_channel_id: nil
        }
      }

      assigns = %{
        policies: [
          %{
            id: "policy-3",
            name: "Ladder",
            repeat_count: 0,
            repeat_interval_seconds: 300,
            resolve_notifies: true,
            steps: [
              %{
                step_number: 1,
                delay_seconds: 0,
                condition: :always,
                step_channels: [%{channel_id: "slack"}]
              }
            ]
          }
        ],
        channel_index: channels
      }

      html =
        rendered_to_string(~H"""
        <Components.policies_panel
          policies={@policies}
          can_manage={false}
          channel_index={@channel_index}
          policy_warnings={%{}}
        />
        """)

      assert html =~ "Slack #noc (disabled)"
      assert html =~ "suppression reason channel disabled"
    end
  end

  describe "channels list" do
    test "health is conveyed by text, not colour alone, and the last error is on demand" do
      channel = %{
        id: "chan-1",
        name: "Slack #noc",
        description: nil,
        enabled: true,
        health: :failing,
        last_success_at: nil,
        last_failure_at: ~U[2026-08-09 12:00:00.000000Z],
        last_error: "invalid_auth",
        max_attempts: 3,
        rate_limit_per_minute: 60,
        execution_route: :control_plane,
        agent_uid: nil,
        partition_id: nil,
        fail_closed: false,
        fallback_channel_id: nil,
        provider: %{display_name: "Slack", provider_type: :native}
      }

      assigns = %{
        streams: %{channels: [{"channels-1", channel}]},
        channel_index: channel_index()
      }

      html =
        rendered_to_string(~H"""
        <Components.channels_tab
          streams={@streams}
          can_manage={false}
          can_test={false}
          channel_form={nil}
          providers={[]}
          channel_index={@channel_index}
          test_result={nil}
          loading={false}
        />
        """)

      assert html =~ "Failing"
      assert html =~ "invalid_auth"
      assert html =~ "Slack"
      # A read-only viewer gets no mutation controls at all.
      refute html =~ "New channel"
      refute html =~ "phx-click=\"edit_channel\""
    end
  end
end
