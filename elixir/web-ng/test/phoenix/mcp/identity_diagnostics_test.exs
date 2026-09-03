defmodule ServiceRadarWebNG.Mcp.IdentityDiagnosticsTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Mcp.IdentityDiagnostics

  @moduletag :db_free

  @uid "sr:0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b"
  @run_id "0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b"

  defmodule StubSRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query_request(%{"query" => query}) do
      send(self(), {:srql, query})

      results =
        cond do
          String.starts_with?(query, "in:devices") ->
            [
              %{
                "uid" => "sr:0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b",
                "hostname" => "farm01",
                "deleted_at" => "2026-08-23T00:00:00Z",
                "deleted_by" => "operator",
                "deleted_reason" => "phantom apipa address"
              }
            ]

          String.starts_with?(query, "in:merge_audit") ->
            [
              %{
                "from_device_id" => "sr:aaa",
                "to_device_id" => "sr:bbb",
                "depth" => 1,
                "direction" => "merged_into",
                "truncated" => false
              },
              %{
                "from_device_id" => "sr:bbb",
                "to_device_id" => "sr:ccc",
                "depth" => 2,
                "direction" => "merged_into",
                "truncated" => false
              }
            ]

          String.starts_with?(query, "in:device_revival_audit") ->
            [%{"device_uid" => "sr:aaa", "previous_deleted_reason" => "cleanup"}]

          String.starts_with?(query, "in:device_identifiers") ->
            [
              %{"identifier_type" => "mac", "matches_current_facts" => true},
              %{"identifier_type" => "mac", "matches_current_facts" => false}
            ]

          String.starts_with?(query, "in:identity_evidence_edges") ->
            [
              %{"direct" => true, "cross_partition" => false, "depth" => 1},
              %{"direct" => false, "cross_partition" => true, "depth" => 2}
            ]

          String.starts_with?(query, "in:identity_reconciliation_runs") ->
            [
              %{
                "run_id" => "0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b",
                "status" => "completed",
                "merges" => 200,
                "max_merges_configured" => 200,
                "merge_cap_reached" => true,
                "blocked_component_devices" => [%{"device_ids" => ["sr:x", "sr:y"]}]
              }
            ]

          true ->
            []
        end

      {:ok, %{"results" => results, "pagination" => %{}}}
    end
  end

  defmodule ForbiddenSRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query_request(_params), do: {:error, :forbidden}
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :srql_module, previous) end)
    :ok
  end

  defp use_srql(module), do: Application.put_env(:serviceradar_web_ng, :srql_module, module)

  defp scope(permissions \\ ["devices.view"]) do
    %Scope{user: nil, permissions: MapSet.new(permissions)}
  end

  defp captured_queries do
    receive do
      {:srql, query} -> [query | captured_queries()]
    after
      0 -> []
    end
  end

  describe "trace/3 query construction" do
    test "every scalar reaches SRQL as a quoted literal, never a bare fragment" do
      use_srql(StubSRQL)

      assert {:ok, _payload} = IdentityDiagnostics.trace(scope(), @uid)

      queries = captured_queries()
      assert queries != []

      for query <- queries do
        # The uid always appears inside double quotes.
        assert query =~ ~s("#{@uid}"), "unquoted uid in: #{query}"
      end

      assert Enum.any?(queries, &String.starts_with?(&1, "in:merge_audit chain:"))
      assert Enum.any?(queries, &String.starts_with?(&1, "in:identity_evidence_edges device:"))
      assert Enum.any?(queries, &String.starts_with?(&1, "in:device_identifiers device_id:"))
      assert Enum.any?(queries, &String.starts_with?(&1, "in:device_revival_audit device_uid:"))
    end

    test "an injection payload in the seed never reaches SRQL at all" do
      use_srql(StubSRQL)

      for payload <- [
            ~s(sr:aaa" OR "1"="1),
            "sr:aaa limit:99999",
            "sr:aaa in:devices deleted:true",
            "'; DROP TABLE platform.device_identifiers; --"
          ] do
        assert {:error, message} = IdentityDiagnostics.trace(scope(), payload)
        assert is_binary(message)
        assert captured_queries() == [], "payload #{payload} was sent to SRQL"
      end
    end

    test "a hostname seed is resolved through a bound device query first" do
      use_srql(StubSRQL)

      assert {:ok, payload} = IdentityDiagnostics.trace(scope(), "farm01")
      assert payload["seed_resolution"] == "resolved by hostname"
      assert payload["device_uid"] == @uid

      queries = captured_queries()

      assert Enum.any?(queries, fn query ->
               String.starts_with?(query, "in:devices hostname:") and query =~ ~s("farm01")
             end)

      # The tombstoned search runs first: a device just tombstoned is exactly
      # what an operator reaches for this tool to explain.
      assert Enum.any?(queries, &(&1 =~ "deleted:true"))
    end
  end

  describe "trace/3 summary" do
    test "answers the questions rather than making the caller re-derive them" do
      use_srql(StubSRQL)

      assert {:ok, payload} = IdentityDiagnostics.trace(scope(), @uid)
      summary = payload["summary"]

      assert summary["tombstoned"]
      assert summary["deleted_reason"] == "phantom apipa address"
      assert summary["survivor"] == "sr:ccc"
      assert summary["corroborated_identifier_count"] == 1
      assert summary["historical_identifier_count"] == 1
      assert summary["direct_evidence_edges"] == 1
      assert summary["transitive_evidence_edges"] == 1
      assert summary["cross_partition_evidence"]
      assert summary["revival_count"] == 1
      refute summary["chain_truncated"]
    end
  end

  describe "explain/2" do
    test "reports the configured cap and that it was reached" do
      use_srql(StubSRQL)

      assert {:ok, payload} = IdentityDiagnostics.explain(scope(), time: "last_24h")
      assert [run] = payload["runs"]
      assert run["merge_cap_reached"]
      assert run["cap_explanation"] =~ "stopped at its configured cap of 200"
    end

    test "only a fixed set of time windows is accepted, never caller text" do
      use_srql(StubSRQL)

      assert {:ok, _} = IdentityDiagnostics.explain(scope(), time: "last_7d")
      assert Enum.any?(captured_queries(), &(&1 =~ "time:last_7d"))

      assert {:ok, _} = IdentityDiagnostics.explain(scope(), time: "last_24h OR 1=1")
      queries = captured_queries()
      assert Enum.any?(queries, &(&1 =~ "time:last_24h"))
      refute Enum.any?(queries, &(&1 =~ "1=1"))
    end

    test "a run_id that is not a uuid is refused before any query runs" do
      use_srql(StubSRQL)

      assert {:error, message} = IdentityDiagnostics.explain(scope(), run_id: "' OR 1=1 --")
      assert message =~ "is not a uuid"
      assert captured_queries() == []
    end

    test "include_evidence seeds an evidence walk per blocked component member" do
      use_srql(StubSRQL)

      assert {:ok, payload} =
               IdentityDiagnostics.explain(scope(), run_id: @run_id, include_evidence: true)

      assert is_list(payload["blocked_component_evidence"])

      queries = captured_queries()
      assert Enum.any?(queries, &(&1 =~ ~s(in:identity_evidence_edges device:"sr:x")))
      assert Enum.any?(queries, &(&1 =~ ~s(in:identity_evidence_edges device:"sr:y")))
    end

    test "omitting include_evidence omits the key entirely" do
      use_srql(StubSRQL)

      assert {:ok, payload} = IdentityDiagnostics.explain(scope(), run_id: @run_id)
      refute Map.has_key?(payload, "blocked_component_evidence")
    end
  end

  describe "permission failures" do
    test "a denial surfaces as an error, not as an empty result set" do
      # Swallowing :forbidden into [] would make a permission problem read as
      # "this device has no merge history", which is the most misleading answer
      # this tool could give.
      use_srql(ForbiddenSRQL)

      assert {:error, message} = IdentityDiagnostics.trace(scope(), @uid)
      assert message =~ "devices.view"

      assert {:error, message} = IdentityDiagnostics.explain(scope())
      assert message =~ "devices.view"
    end

    test "the entity gate rejects a caller lacking devices.view before SRQL runs" do
      use_srql(StubSRQL)

      assert {:error, _} =
               IdentityDiagnostics.trace(scope(["observability.logs.view"]), @uid)
    end
  end
end
