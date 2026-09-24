defmodule ServiceRadar.Observability.MtrAutomationDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrAutomationDispatcher

  describe "classify_transition/2" do
    test "classifies healthy to degraded as incident" do
      assert {:incident, "degraded"} =
               MtrAutomationDispatcher.classify_transition(:healthy, :degraded)
    end

    test "classifies healthy to unavailable as incident" do
      assert {:incident, "unavailable"} =
               MtrAutomationDispatcher.classify_transition(:healthy, :unavailable)
    end

    test "classifies degraded to healthy as recovery" do
      assert {:recovery, "recovery"} =
               MtrAutomationDispatcher.classify_transition(:degraded, :healthy)
    end

    test "ignores non-actionable transitions" do
      assert :ignore = MtrAutomationDispatcher.classify_transition(:healthy, :healthy)
      assert :ignore = MtrAutomationDispatcher.classify_transition(:degraded, :offline)
    end
  end

  describe "target_ctx_from_health_event/1" do
    test "extracts explicit target metadata" do
      event = %{
        entity_type: :checker,
        entity_id: "check-1",
        metadata: %{
          "target" => "google.com",
          "target_ip" => "8.8.8.8",
          "target_device_uid" => "dev-1",
          "partition_id" => "p1"
        }
      }

      assert {:ok, ctx} = MtrAutomationDispatcher.target_ctx_from_health_event(event)
      assert ctx.target == "google.com"
      assert ctx.target_ip == "8.8.8.8"
      assert ctx.target_device_uid == "dev-1"
      assert ctx.partition_id == "p1"
      assert ctx.target_key == "device:dev-1"
    end

    test "falls back to entity ip for target" do
      event = %{entity_type: :custom, entity_id: "1.1.1.1", metadata: %{}}

      assert {:ok, ctx} = MtrAutomationDispatcher.target_ctx_from_health_event(event)
      assert ctx.target == "1.1.1.1"
      assert ctx.target_ip == "1.1.1.1"
      assert ctx.target_key == "ip:1.1.1.1"
    end

    test "returns error when no target can be inferred" do
      event = %{entity_type: :custom, entity_id: "service-abc", metadata: %{}}

      assert {:error, :missing_target} =
               MtrAutomationDispatcher.target_ctx_from_health_event(event)
    end
  end

  describe "target_contexts_from_srql/3" do
    test "normalizes device SRQL queries and materializes target contexts" do
      translate_fn = fn "in:devices tags.role:edge limit:25", 25, nil, nil, nil ->
        {:ok,
         Jason.encode!(%{
           "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices",
           "params" => []
         })}
      end

      query_fn = fn "select ip, hostname, uid, partition_id, gateway_id from devices", [] ->
        {:ok,
         %Postgrex.Result{
           columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
           rows: [
             ["192.0.2.10", "edge-01", "dev-1", "p1", "gw-1"],
             ["192.0.2.11", nil, "dev-2", nil, nil]
           ]
         }}
      end

      assert {:ok, targets} =
               MtrAutomationDispatcher.target_contexts_from_srql("tags.role:edge", 25,
                 translate_fn: translate_fn,
                 query_fn: query_fn,
                 managed_target_filter_fn: & &1
               )

      assert targets == [
               %{
                 target: "192.0.2.10",
                 target_ip: "192.0.2.10",
                 target_device_uid: "dev-1",
                 partition_id: "p1",
                 gateway_id: "gw-1",
                 target_key: "device:dev-1"
               },
               %{
                 target: "192.0.2.11",
                 target_ip: "192.0.2.11",
                 target_device_uid: "dev-2",
                 partition_id: "default",
                 gateway_id: nil,
                 target_key: "device:dev-2"
               }
             ]
    end

    test "continues paging until it finds enough eligible target contexts" do
      translate_fn = fn
        "in:devices tags.role:edge limit:2", 2, nil, nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_1",
             "params" => [],
             "pagination" => %{"limit" => 2, "next_cursor" => "cursor-2"}
           })}

        "in:devices tags.role:edge limit:2", 2, "cursor-2", nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_2",
             "params" => [],
             "pagination" => %{"limit" => 2}
           })}
      end

      query_fn = fn
        "select ip, hostname, uid, partition_id, gateway_id from devices_page_1", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [
               [nil, "ignored-01", "dev-ignored-1", "p1", "gw-1"],
               [nil, "ignored-02", "dev-ignored-2", "p1", "gw-1"]
             ]
           }}

        "select ip, hostname, uid, partition_id, gateway_id from devices_page_2", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [
               ["192.0.2.10", "edge-01", "dev-1", "p1", "gw-1"],
               ["192.0.2.11", "edge-02", "p2-dev-2", "p2", nil]
             ]
           }}
      end

      assert {:ok, targets} =
               MtrAutomationDispatcher.target_contexts_from_srql("tags.role:edge", 2,
                 translate_fn: translate_fn,
                 query_fn: query_fn,
                 managed_target_filter_fn: & &1
               )

      assert targets == [
               %{
                 target: "192.0.2.10",
                 target_ip: "192.0.2.10",
                 target_device_uid: "dev-1",
                 partition_id: "p1",
                 gateway_id: "gw-1",
                 target_key: "device:dev-1"
               },
               %{
                 target: "192.0.2.11",
                 target_ip: "192.0.2.11",
                 target_device_uid: "p2-dev-2",
                 partition_id: "p2",
                 gateway_id: nil,
                 target_key: "device:p2-dev-2"
               }
             ]
    end

    # A profile with no selector limit must trace its whole scope. Regression: the
    # limit defaulted to 100, which doubled as the page size AND the cap, so a
    # scope of 251 devices silently traced its first 100 with nothing logged.
    test "with no limit, pages to exhaustion and caps nothing" do
      translate_fn = fn
        "in:devices tags.role:edge limit:2", 2, nil, nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_1",
             "params" => [],
             "pagination" => %{"limit" => 2, "next_cursor" => "cursor-2"}
           })}

        "in:devices tags.role:edge limit:2", 2, "cursor-2", nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_2",
             "params" => [],
             "pagination" => %{"limit" => 2}
           })}
      end

      query_fn = fn
        "select ip, hostname, uid, partition_id, gateway_id from devices_page_1", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [
               ["192.0.2.10", "edge-01", "dev-1", "p1", "gw-1"],
               ["192.0.2.11", "edge-02", "dev-2", "p1", "gw-1"]
             ]
           }}

        "select ip, hostname, uid, partition_id, gateway_id from devices_page_2", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [
               ["192.0.2.12", "edge-03", "dev-3", "p1", "gw-1"],
               ["192.0.2.13", "edge-04", "dev-4", "p1", "gw-1"]
             ]
           }}
      end

      assert {:ok, targets} =
               MtrAutomationDispatcher.target_contexts_from_srql("tags.role:edge", nil,
                 translate_fn: translate_fn,
                 query_fn: query_fn,
                 managed_target_filter_fn: & &1,
                 page_size: 2
               )

      assert Enum.map(targets, & &1.target_device_uid) == ["dev-1", "dev-2", "dev-3", "dev-4"]
    end

    # A ceiling larger than one page must not collapse to the page size: the
    # request keeps paging until the cursor runs out or the ceiling is hit.
    test "an explicit limit above the page size still pages past one page" do
      translate_fn = fn
        "in:devices tags.role:edge limit:2", 2, nil, nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_1",
             "params" => [],
             "pagination" => %{"limit" => 2, "next_cursor" => "cursor-2"}
           })}

        "in:devices tags.role:edge limit:2", 2, "cursor-2", nil, nil ->
          {:ok,
           Jason.encode!(%{
             "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices_page_2",
             "params" => [],
             "pagination" => %{"limit" => 2}
           })}
      end

      query_fn = fn
        "select ip, hostname, uid, partition_id, gateway_id from devices_page_1", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [
               ["192.0.2.10", "edge-01", "dev-1", "p1", "gw-1"],
               ["192.0.2.11", "edge-02", "dev-2", "p1", "gw-1"]
             ]
           }}

        "select ip, hostname, uid, partition_id, gateway_id from devices_page_2", [] ->
          {:ok,
           %Postgrex.Result{
             columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
             rows: [["192.0.2.12", "edge-03", "dev-3", "p1", "gw-1"]]
           }}
      end

      assert {:ok, targets} =
               MtrAutomationDispatcher.target_contexts_from_srql("tags.role:edge", 1200,
                 translate_fn: translate_fn,
                 query_fn: query_fn,
                 managed_target_filter_fn: & &1,
                 page_size: 2
               )

      assert Enum.map(targets, & &1.target_device_uid) == ["dev-1", "dev-2", "dev-3"]
    end

    test "returns SRQL errors" do
      translate_fn = fn "in:devices hostname:bad limit:10", 10, nil, nil, nil ->
        {:error, :bad_query}
      end

      assert {:error, :bad_query} =
               MtrAutomationDispatcher.target_contexts_from_srql("hostname:bad", 10,
                 translate_fn: translate_fn
               )
    end
  end

  describe "candidate_agents/2" do
    test "builds candidates from the command bus session listing" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["mtr", "sweep"], "in_flight" => 2}),
        session("agent-b", "default", %{"capabilities" => ["sweep"]})
      ]

      candidates =
        MtrAutomationDispatcher.candidate_agents(%{partition_id: "default"},
          session_lister: fn -> sessions end
        )

      assert [
               %{agent_id: "agent-a", partition_id: "default", mtr_capable: true, in_flight: 2},
               %{agent_id: "agent-b", mtr_capable: false}
             ] = candidates
    end

    test "keeps only sessions in the target partition" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["mtr"]}),
        session("agent-b", "site-02", %{"capabilities" => ["mtr"]})
      ]

      assert [%{agent_id: "agent-b"}] =
               MtrAutomationDispatcher.candidate_agents(%{partition_id: "site-02"},
                 session_lister: fn -> sessions end
               )

      assert ["agent-a", "agent-b"] =
               %{partition_id: nil}
               |> MtrAutomationDispatcher.candidate_agents(session_lister: fn -> sessions end)
               |> Enum.map(& &1.agent_id)
    end

    test "rejects legacy keys and sessions whose metadata names another principal" do
      sessions = [
        %{key: {:agent_control, "agent-legacy", :gateway@host01}, pid: self(), metadata: %{}},
        session("agent-a", "default", %{"agent_id" => "agent-other"})
      ]

      assert [] =
               MtrAutomationDispatcher.candidate_agents(%{partition_id: "default"},
                 session_lister: fn -> sessions end
               )
    end
  end

  describe "dispatch_for_mode/5" do
    test "threads an injected session_lister to candidate selection" do
      counter = :counters.new(1, [])

      lister = fn ->
        :counters.add(counter, 1, 1)
        []
      end

      target_ctx = %{
        target: "192.0.2.10",
        target_ip: "192.0.2.10",
        partition_id: "default",
        target_key: "device:sr:00000000-0000-0000-0000-000000000001"
      }

      policy = %{target_selector: %{}, baseline_canary_vantages: 0}

      assert {:error, :no_candidates} =
               MtrAutomationDispatcher.dispatch_for_mode(
                 target_ctx,
                 policy,
                 :baseline,
                 nil,
                 session_lister: lister
               )

      assert :counters.get(counter, 1) == 1
    end

    # A non-empty listing reaches preferred-agent selection. That step runs before
    # the cooldown read, so a preference no candidate satisfies is decided without
    # a database; the successful path continues into the cooldown read and the
    # dispatch-window write, and is covered through select_agents/4 below.
    test "checks the policy's preferred agent against a non-empty injected listing" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["mtr"]}),
        session("agent-b", "default", %{"capabilities" => ["mtr"]})
      ]

      policy = %{target_selector: %{"agent_id" => "agent-z"}, baseline_canary_vantages: 0}

      assert {:error, :preferred_agent_unavailable} =
               MtrAutomationDispatcher.dispatch_for_mode(
                 dispatch_target_ctx(),
                 policy,
                 :baseline,
                 nil,
                 session_lister: fn -> sessions end
               )
    end
  end

  describe "select_agents/4" do
    test "selects the preferred agent from a non-empty listing even when it ranks lower" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["mtr"], "in_flight" => 0}),
        session("agent-b", "default", %{"capabilities" => ["mtr"], "in_flight" => 8})
      ]

      policy = %{target_selector: %{"agent_id" => "agent-b"}, baseline_canary_vantages: 0}

      assert {:ok, ["agent-b"]} =
               MtrAutomationDispatcher.select_agents(dispatch_target_ctx(), policy, :baseline,
                 session_lister: fn -> sessions end
               )
    end

    test "keeps only the preferred agents that are online" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["mtr"]}),
        session("agent-c", "default", %{"capabilities" => ["mtr"]})
      ]

      policy = %{
        target_selector: %{"agent_ids" => ["agent-c", "agent-offline"]},
        baseline_canary_vantages: 0
      }

      assert {:ok, ["agent-c"]} =
               MtrAutomationDispatcher.select_agents(dispatch_target_ctx(), policy, :baseline,
                 session_lister: fn -> sessions end
               )
    end

    test "without a preference, ranks only MTR-capable candidates" do
      sessions = [
        session("agent-a", "default", %{"capabilities" => ["sweep"]}),
        session("agent-b", "default", %{"capabilities" => ["mtr"]})
      ]

      policy = %{target_selector: %{}, baseline_canary_vantages: 0}

      assert {:ok, ["agent-b"]} =
               MtrAutomationDispatcher.select_agents(dispatch_target_ctx(), policy, :baseline,
                 session_lister: fn -> sessions end
               )

      assert {:error, :no_candidates} =
               MtrAutomationDispatcher.select_agents(dispatch_target_ctx(), policy, :incident,
                 session_lister: fn -> [hd(sessions)] end
               )
    end
  end

  defp dispatch_target_ctx do
    %{
      target: "192.0.2.10",
      target_ip: "192.0.2.10",
      partition_id: "default",
      target_key: "device:sr:00000000-0000-0000-0000-000000000001"
    }
  end

  defp session(agent_id, partition_id, metadata) do
    %{
      key: {:agent_control, partition_id, agent_id, :gateway@host01},
      agent_id: agent_id,
      pid: self(),
      partition_id: partition_id,
      metadata: Map.merge(%{"agent_id" => agent_id, "partition_id" => partition_id}, metadata)
    }
  end
end
