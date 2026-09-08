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

  alias ServiceRadarWebNG.Observability.ContractRegistry
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

  defp render_deliveries(rows, timezone \\ "Etc/UTC") do
    assigns = %{
      streams: %{deliveries: Enum.with_index(rows, &{"deliveries-#{&2}", &1})},
      filters: DeliveryFilters.empty(),
      channel_index: channel_index(),
      timezone: timezone
    }

    rendered_to_string(~H"""
    <Components.deliveries_tab
      streams={@streams}
      filters={@filters}
      channel_index={@channel_index}
      selected={nil}
      limit={100}
      loading={false}
      timezone={@timezone}
    />
    """)
  end

  defp assert_user_time(html, id, datetime, timezone) do
    time = html |> LazyHTML.from_fragment() |> LazyHTML.query("time##{id}")

    assert LazyHTML.attribute(time, "datetime") == [datetime]
    assert LazyHTML.attribute(time, "data-user-time-zone") == [timezone]
  end

  describe "delivery log" do
    test "absolute delivery times use the saved timezone without changing their canonical instants" do
      html =
        render_deliveries(
          [
            delivery(%{
              state: :suppressed,
              suppression_reason: :silence,
              occurrence_count: 2,
              last_evaluated_at: ~U[2026-08-09 12:01:00.000000Z],
              next_attempt_at: ~U[2026-08-09 12:02:00.000000Z],
              queued_at: ~U[2026-08-09 12:03:00.000000Z],
              started_at: ~U[2026-08-09 12:04:00.000000Z],
              finished_at: ~U[2026-08-09 12:05:00.000000Z]
            })
          ],
          "America/Chicago"
        )

      delivery_id = "018f7a10-0000-7000-8000-00000000000a"

      for {field, datetime} <- [
            {"last-evaluated-at", "2026-08-09T12:01:00.000000Z"},
            {"next-attempt-at", "2026-08-09T12:02:00.000000Z"},
            {"queued-at", "2026-08-09T12:03:00.000000Z"},
            {"started-at", "2026-08-09T12:04:00.000000Z"},
            {"finished-at", "2026-08-09T12:05:00.000000Z"}
          ] do
        assert_user_time(
          html,
          "notification-delivery-#{delivery_id}-#{field}",
          datetime,
          "America/Chicago"
        )
      end
    end

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
    test "health timestamps use the saved timezone and stable channel identity" do
      channel = %{
        id: "chan-timezone",
        name: "Timezone channel",
        description: nil,
        enabled: true,
        health: :healthy,
        last_success_at: ~U[2026-08-09 12:00:00.000000Z],
        last_failure_at: ~U[2026-08-09 13:00:00.000000Z],
        last_error: nil,
        max_attempts: 3,
        rate_limit_per_minute: nil,
        execution_route: :control_plane,
        agent_uid: nil,
        partition_id: nil,
        fail_closed: false,
        fallback_channel_id: nil,
        provider: %{display_name: "Webhook", provider_type: :native}
      }

      assigns = %{
        streams: %{channels: [{"channels-timezone", channel}]},
        channel_index: %{"chan-timezone" => channel},
        timezone: "America/Chicago"
      }

      html =
        rendered_to_string(~H"""
        <Components.channels_tab
          streams={@streams}
          can_manage={false}
          channel_index={@channel_index}
          timezone={@timezone}
        />
        """)

      assert_user_time(
        html,
        "notification-channel-chan-timezone-last-success-at",
        "2026-08-09T12:00:00.000000Z",
        "America/Chicago"
      )

      assert_user_time(
        html,
        "notification-channel-chan-timezone-last-failure-at",
        "2026-08-09T13:00:00.000000Z",
        "America/Chicago"
      )
    end

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

    test "a fail-closed edge channel carries the loss on its saved row" do
      channel = %{
        id: "edge-1",
        name: "Site A agent page",
        description: nil,
        enabled: true,
        health: :healthy,
        last_success_at: nil,
        last_failure_at: nil,
        last_error: nil,
        max_attempts: 3,
        rate_limit_per_minute: nil,
        execution_route: :edge_agent,
        agent_uid: "agent-a",
        partition_id: "site-a",
        fail_closed: true,
        fallback_channel_id: nil,
        provider: %{display_name: "Mattermost", provider_type: :wasm_plugin}
      }

      assigns = %{
        streams: %{channels: [{"channels-1", channel}]},
        channel_index: Map.put(channel_index(), "edge-1", channel)
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

      assert html =~ "Fail closed: page is lost"
      assert html =~ "site-a"
    end

    test "a control-plane channel gets no failover advisory badge" do
      channel = %{
        id: "chan-1",
        name: "Slack #noc",
        description: nil,
        enabled: true,
        health: :healthy,
        last_success_at: nil,
        last_failure_at: nil,
        last_error: nil,
        max_attempts: 3,
        rate_limit_per_minute: nil,
        execution_route: :control_plane,
        agent_uid: nil,
        partition_id: nil,
        fail_closed: true,
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

      # fail_closed still shows as configuration, but the edge-route advisory
      # does not, because there is no site agent for the platform to lose.
      assert html =~ "fail closed: no failover"
      refute html =~ "Fail closed: page is lost"
      refute html =~ "No failover</"
    end
  end

  describe "notification schedule presentation" do
    test "silence windows use the saved timezone and stable silence identity" do
      silence = %{
        id: "silence-timezone",
        name: "Maintenance",
        created_by: "operator",
        state: :scheduled,
        starts_at: ~U[2026-08-09 12:00:00.000000Z],
        ends_at: ~U[2026-08-09 14:00:00.000000Z],
        matchers: %{},
        comment: "Maintenance window"
      }

      assigns = %{
        streams: %{silences: [{"silences-timezone", silence}]},
        timezone: "America/Chicago"
      }

      html =
        rendered_to_string(~H"""
        <Components.silences_tab
          streams={@streams}
          can_manage={false}
          timezone={@timezone}
        />
        """)

      assert_user_time(
        html,
        "notification-silence-silence-timezone-starts-at",
        "2026-08-09T12:00:00.000000Z",
        "America/Chicago"
      )

      assert_user_time(
        html,
        "notification-silence-silence-timezone-ends-at",
        "2026-08-09T14:00:00.000000Z",
        "America/Chicago"
      )
    end

    test "provider definition history uses the saved timezone and version identity" do
      assigns = %{
        versions: %{
          provider: %{
            id: "provider-timezone",
            display_name: "Webhook",
            definition_version: 2
          },
          channels: [],
          entries: [
            %{
              number: 2,
              current?: true,
              recorded_at: ~U[2026-08-09 15:00:00.000000Z],
              action: "update",
              definition: %{}
            }
          ]
        },
        timezone: "America/Chicago"
      }

      html =
        rendered_to_string(~H"""
        <Components.provider_versions_panel
          versions={@versions}
          can_manage={false}
          timezone={@timezone}
        />
        """)

      assert_user_time(
        html,
        "notification-provider-provider-timezone-version-2-recorded-at",
        "2026-08-09T15:00:00.000000Z",
        "America/Chicago"
      )
    end
  end

  describe "channel editor failover section" do
    defp render_failover(params, index \\ %{}) do
      assigns = %{params: params, channel_index: index}

      rendered_to_string(~H"""
      <Components.failover_fields params={@params} channel_index={@channel_index} />
      """)
    end

    defp edge_params(overrides) do
      Map.merge(
        %{
          "id" => "edge-1",
          "execution_route" => "edge_agent",
          "agent_uid" => "agent-a",
          "fail_closed" => "false",
          "fallback_channel_id" => ""
        },
        overrides
      )
    end

    test "the consequence of fail closed is on screen at the moment it is ticked" do
      html = render_failover(edge_params(%{"fail_closed" => "true"}))

      assert html =~ ~s(data-channel-failover-advisory="error")
      assert html =~ "Fail closed on a site-agent channel loses the page"
      assert html =~ "agent-a"
      assert html =~ "Set a control-plane failover channel"
    end

    test "an edge channel with no failover is warned before it is saved" do
      html = render_failover(edge_params(%{}))

      assert html =~ ~s(data-channel-failover-advisory="warning")
      assert html =~ "No failover channel for a site-agent channel"
    end

    test "a control-plane failover reads as resolved rather than silent" do
      index = %{
        "cp-1" => %{
          id: "cp-1",
          name: "Slack #noc",
          enabled: true,
          execution_route: :control_plane,
          partition_id: nil,
          agent_uid: nil,
          fail_closed: false,
          fallback_channel_id: nil
        }
      }

      html = render_failover(edge_params(%{"fallback_channel_id" => "cp-1"}), index)

      assert html =~ ~s(data-channel-failover-advisory="ok")
      assert html =~ "Failover reaches the control plane"
    end

    test "the edge route gets the at-most-once explanation, the control plane does not" do
      edge = render_failover(edge_params(%{}))
      control = render_failover(%{"execution_route" => "control_plane", "id" => "cp-1"})

      assert edge =~ "Agent commands are at-most-once"
      assert edge =~ ~s(data-execution-route="edge_agent")
      refute control =~ "Agent commands are at-most-once"
      refute control =~ "data-channel-failover-advisory"
    end

    test "both fields are always present, on either route" do
      for html <- [
            render_failover(edge_params(%{})),
            render_failover(%{"execution_route" => "control_plane", "id" => "cp-1"})
          ] do
        assert html =~ ~s(name="channel[fallback_channel_id]")
        assert html =~ ~s(name="channel[fail_closed]")
      end
    end

    test "an operator-supplied channel name in the picker is escaped, never markup" do
      index = %{
        "cp-1" => %{
          id: "cp-1",
          name: "<script>alert(1)</script>",
          enabled: true,
          execution_route: :control_plane,
          partition_id: nil,
          agent_uid: nil,
          fail_closed: false,
          fallback_channel_id: nil
        }
      }

      html = render_failover(edge_params(%{}), index)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  # Tasks 3.5.4: the three notification surfaces render from package-supplied
  # contracts, resolved at runtime. These are render tests rather than unit
  # tests on `Contracts` because what the task owes is that the SCREEN changes
  # when a package is installed, not that a function returns a map.
  describe "package-supplied contracts on the notification surfaces" do
    @package_id "33333333-3333-3333-3333-333333333333"

    @health_contract %{
      "id" => "com.thirdparty.pageco.health.display",
      "version" => "1.0.0",
      "schema_id" => "pageco",
      "schema_version" => "1.0.0",
      "surface" => "notification_channel_health",
      "widgets" => [
        %{
          "type" => "facts",
          "fields" => [
            %{"label" => "Upstream status", "path" => "last_error"},
            %{
              "label" => "Last success",
              "path" => "last_success_at",
              "format" => "timestamp"
            }
          ]
        }
      ]
    }

    @delivery_contract %{
      "id" => "com.thirdparty.pageco.delivery.display",
      "version" => "1.0.0",
      "schema_id" => "pageco",
      "schema_version" => "1.0.0",
      "surface" => "notification_delivery",
      "widgets" => [
        %{
          "type" => "facts",
          "fields" => [
            %{"label" => "Completed", "path" => "completed_at", "format" => "timestamp"}
          ]
        }
      ]
    }

    @package %{
      id: @package_id,
      plugin_id: "pageco",
      version: "2.0.0",
      display_contracts: %{
        "com.thirdparty.pageco.health.display@1.0.0" => @health_contract,
        "com.thirdparty.pageco.delivery.display@1.0.0" => @delivery_contract
      },
      manifest: %{
        "id" => "pageco",
        "name" => "PageCo",
        "version" => "2.0.0",
        "entrypoint" => "run",
        "outputs" => "serviceradar.plugin_result.v1",
        "capabilities" => ["log", "notify:v1"],
        "resources" => %{"requested_memory_mb" => 16, "requested_cpu_ms" => 500},
        "notifications" => [
          %{
            "key" => "pageco",
            "display_name" => "PageCo",
            "entrypoint" => "notify",
            "capabilities" => ["send", "test"],
            "payload_formats" => ["json"],
            "config_schema" => %{
              "type" => "object",
              "properties" => %{
                "escalation_policy" => %{"type" => "string", "title" => "Escalation policy"}
              }
            }
          }
        ]
      }
    }

    @provider %{
      id: "provider-pageco",
      display_name: "PageCo",
      provider_type: :wasm_plugin,
      plugin_package_id: @package_id,
      action_key: "pageco",
      supported_routes: [:control_plane],
      default_max_attempts: 3,
      # Stale: what the provider row was created with, before the package moved on.
      config_schema: %{
        "type" => "object",
        "properties" => %{"legacy_token" => %{"type" => "string", "title" => "Legacy token"}}
      }
    }

    setup do
      if is_nil(Process.whereis(ContractRegistry)) do
        start_supervised!({ContractRegistry, []})
      end

      original = Application.get_env(:serviceradar_web_ng, ContractRegistry)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:serviceradar_web_ng, ContractRegistry)
          config -> Application.put_env(:serviceradar_web_ng, ContractRegistry, config)
        end

        ContractRegistry.refresh()
      end)

      :ok
    end

    defp install(packages) do
      Application.put_env(:serviceradar_web_ng, ContractRegistry, packages: packages)
      :ok = ContractRegistry.refresh()
    end

    defp channel_form do
      %{
        mode: :new,
        record: nil,
        provider: @provider,
        params: %{"name" => "PageCo primary", "provider_id" => "provider-pageco"},
        config_params: %{},
        warnings: []
      }
    end

    test "the channel config form renders the package manifest's fields, not the stored copy" do
      install([@package])

      assigns = %{form: channel_form(), channel_index: %{}}

      html =
        rendered_to_string(~H"""
        <Components.channel_editor
          form={@form}
          providers={[]}
          channel_index={@channel_index}
          can_test={false}
          test_result={nil}
        />
        """)

      assert html =~ "Escalation policy"
      assert html =~ "from the package manifest"
      refute html =~ "Legacy token"
    end

    test "an uninstalled package falls back to the stored schema and says so" do
      install([])

      assigns = %{form: channel_form(), channel_index: %{}}

      html =
        rendered_to_string(~H"""
        <Components.channel_editor
          form={@form}
          providers={[]}
          channel_index={@channel_index}
          can_test={false}
          test_result={nil}
        />
        """)

      assert html =~ "Legacy token"
      assert html =~ "from the provider record"
      assert html =~ "not in the runtime contract index"
    end

    test "channel health renders the package's health contract" do
      install([@package])

      channel = %{
        id: "chan-pageco",
        name: "PageCo primary",
        description: nil,
        enabled: true,
        health: :failing,
        last_success_at: ~U[2026-08-09 12:00:00.000000Z],
        last_failure_at: nil,
        last_error: "upstream 503",
        max_attempts: 3,
        rate_limit_per_minute: nil,
        execution_route: :control_plane,
        agent_uid: nil,
        partition_id: nil,
        fail_closed: false,
        fallback_channel_id: nil,
        provider: @provider
      }

      assigns = %{
        streams: %{channels: [{"channels-1", channel}]},
        channel_index: %{"chan-pageco" => channel}
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
          timezone="America/Chicago"
        />
        """)

      # The package's own label for the field, which nothing in web-ng knows.
      assert html =~ "Upstream status"
      assert html =~ "upstream 503"

      assert_user_time(
        html,
        "channel-chan-pageco-health-contract-widget-0-field-1-time",
        "2026-08-09T12:00:00.000000Z",
        "America/Chicago"
      )
    end

    test "delivery detail passes the saved timezone to a package contract" do
      install([@package])

      selected = %{
        delivery:
          delivery(%{
            result_summary: %{"completed_at" => "2026-08-09T13:00:00.000000Z"}
          }),
        chain: %{origin: nil, successors: []}
      }

      assigns = %{
        selected: selected,
        channel_index: %{
          "chan-1" => %{
            id: "chan-1",
            name: "PageCo primary",
            provider: @provider
          }
        }
      }

      html =
        rendered_to_string(~H"""
        <Components.delivery_detail
          selected={@selected}
          channel_index={@channel_index}
          timezone="America/Chicago"
        />
        """)

      assert_user_time(
        html,
        "delivery-018f7a10-0000-7000-8000-00000000000a-contract-widget-0-field-0-time",
        "2026-08-09T13:00:00.000000Z",
        "America/Chicago"
      )
    end
  end
end
