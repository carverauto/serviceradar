defmodule ServiceRadarSRQL.NativeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native

  test "encodes normalized rows as an Arrow IPC file payload" do
    rows =
      Jason.encode!([
        %{
          "site_code" => "ORD",
          "ap_count" => 42,
          "latitude" => 41.9742,
          "active" => true
        },
        %{
          "site_code" => "ZZC",
          "ap_count" => 17,
          "latitude" => 11.0000,
          "active" => false
        }
      ])

    assert {:ok, payload} =
             Native.encode_arrow_json(["site_code", "ap_count", "latitude", "active"], rows)

    assert <<"ARROW1", _::binary>> = payload
  end

  describe "translate with a permitted-signal set" do
    test "translate/5 supplies no set, so otel_services fails closed" do
      assert {:error, "forbidden: " <> _} =
               Native.translate("in:otel_services", 50, nil, nil, nil)
    end

    test "translate/6 narrows otel_services to the permitted signals" do
      assert {:ok, json} = Native.translate("in:otel_services", 50, nil, nil, nil, ["logs"])
      assert %{"sql" => sql} = Jason.decode!(json)
      assert sql =~ "logs_last_seen_at AS last_seen"
      refute sql =~ "traces_last_seen_at"
    end

    test "translate/6 rejects a signal outside the set as forbidden" do
      assert {:error, "forbidden: " <> _} =
               Native.translate("in:otel_services signal:traces", 50, nil, nil, nil, ["logs"])
    end

    test "translate/6 reports a malformed signal filter as an invalid request" do
      assert {:error, "invalid request: " <> _} =
               Native.translate("in:otel_services !signal:logs", 50, nil, nil, nil, ["logs"])
    end

    test "translate/5 is unchanged for other entities" do
      assert {:ok, _json} = Native.translate("in:services", 10, nil, nil, nil)
    end
  end

  describe "declarative_check_results and declarative.<slug> translation" do
    test "translates declarative_check_results filters, time bounds, and sorting" do
      query =
        "in:declarative_check_results check_slug:checkout-api-health " <>
          "check_id:00000000-0000-7000-8000-000000000001 target_key:device:sr:dev-0001 " <>
          "device_uid:sr:dev-0001 verdict:http_timeout status:down state:enabled " <>
          "evaluated_at:>=2026-11-18T00:00:00Z changed_at:<=2026-11-18T06:00:00Z " <>
          "sort:changed_at:desc"

      assert {:ok, ast_json} = Native.parse_ast(query)
      assert %{"entity" => "declarative_check_results"} = Jason.decode!(ast_json)

      assert {:ok, sql_json} = Native.translate(query, 25, nil, nil, nil)
      assert %{"sql" => sql, "params" => params} = Jason.decode!(sql_json)
      assert sql =~ "declarative_check_instances"
      assert sql =~ "declarative_checks"
      assert sql =~ "AS check_slug"
      assert Enum.any?(params, &(&1["t"] == "uuid"))
      assert Enum.any?(params, &(&1["t"] == "timestamptz"))
    end

    test "translates declarative_check_results stats rollups" do
      query =
        "in:declarative_check_results state:enabled stats:count() as total by check_slug,status,verdict"

      assert {:ok, sql_json} = Native.translate(query, 50, nil, nil, nil)
      assert %{"sql" => sql} = Jason.decode!(sql_json)
      assert sql =~ "GROUP BY"
      assert sql =~ "'check_slug', declarative_checks.slug"
      assert sql =~ "'status', declarative_check_instances.status"
      assert sql =~ "'verdict', declarative_check_instances.verdict"
    end

    test "translates devices declarative.<slug> and declarative.<slug>.status filters" do
      verdict_query = "in:devices declarative.edge-tls-expiry:cert_expiring_soon"
      assert {:ok, verdict_json} = Native.translate(verdict_query, 25, nil, nil, nil)
      assert %{"sql" => verdict_sql} = Jason.decode!(verdict_json)
      assert verdict_sql =~ "EXISTS (SELECT 1 FROM declarative_check_instances r"
      assert verdict_sql =~ "r.verdict = ANY("

      status_query = "in:devices declarative.edge-tls-expiry.status:(degraded,down)"
      assert {:ok, status_json} = Native.translate(status_query, 25, nil, nil, nil)
      assert %{"sql" => status_sql} = Jason.decode!(status_json)
      assert status_sql =~ "r.status = ANY("
    end
  end

  test "rejects invalid row JSON" do
    assert {:error, reason} = Native.encode_arrow_json(["site_code"], "{")
    assert reason =~ "invalid rows JSON"
  end
end
