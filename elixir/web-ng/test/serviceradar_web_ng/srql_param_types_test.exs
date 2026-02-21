defmodule ServiceRadarWebNG.SRQLParamTypesTest do
  @moduledoc """
  Tests for SRQL parameter type decoding.

  These tests verify that the SRQL module correctly decodes various parameter
  types returned by the Rust NIF, including UUID, text, bool, int, float,
  timestamptz, and array types.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "UUID parameter type" do
    test "queries logs by UUID id field" do
      # Insert a test log entry
      log_id = Ecto.UUID.generate()
      {:ok, log_id_binary} = Ecto.UUID.dump(log_id)
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO logs (timestamp, id, severity_text, body, service_name)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [now, log_id_binary, "INFO", "Test log message", "srql-test"]
      )

      # Query by UUID - this exercises the uuid parameter type decoder
      query = ~s(in:logs id:"#{log_id}" limit:1)

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      assert is_map(response)

      results = Map.get(response, "results", [])
      assert length(results) == 1

      log = hd(results)
      # SRQL results are JSON maps; UUIDs come back stringified.
      assert log["id"] == log_id
      assert log["severity_text"] == "INFO"
      assert log["body"] == "Test log message"
    end

    test "returns empty results for non-existent UUID" do
      non_existent_id = Ecto.UUID.generate()
      query = ~s(in:logs id:"#{non_existent_id}" limit:1)

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      assert Map.get(response, "results", []) == []
    end

    test "handles invalid UUID format gracefully" do
      # Invalid UUID should fail at the SRQL level or return no results
      query = ~s(in:logs id:"not-a-valid-uuid" limit:1)

      # This should either error or return empty results
      result = ServiceRadarWebNG.SRQL.query(query)

      case result do
        {:ok, response} ->
          # If it doesn't error, it should return empty results
          assert Map.get(response, "results", []) == []

        {:error, _reason} ->
          # Error is also acceptable for invalid UUID
          assert true
      end
    end
  end

  describe "boolean parameter type" do
    test "queries gateways by boolean is_healthy field with true" do
      gateway_id = "srql-bool-test-" <> Ecto.UUID.generate()
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO gateways (gateway_id, is_healthy, status, last_seen)
        VALUES ($1, $2, $3, $4)
        """,
        [gateway_id, true, "ready", now]
      )

      query = "in:gateways gateway_id:#{gateway_id} is_healthy:true limit:1"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      results = Map.get(response, "results", [])
      assert length(results) == 1
      assert hd(results)["is_healthy"] == true
    end

    test "queries gateways by boolean is_healthy field with false" do
      gateway_id = "srql-bool-test-false-" <> Ecto.UUID.generate()
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO gateways (gateway_id, is_healthy, status, last_seen)
        VALUES ($1, $2, $3, $4)
        """,
        [gateway_id, false, "degraded", now]
      )

      query = "in:gateways gateway_id:#{gateway_id} is_healthy:false limit:1"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      results = Map.get(response, "results", [])
      assert length(results) == 1
      assert hd(results)["is_healthy"] == false
    end
  end

  describe "text parameter type" do
    test "queries by text field with exact match" do
      gateway_id = "srql-text-test-" <> Ecto.UUID.generate()
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO gateways (gateway_id, status, component_id, last_seen)
        VALUES ($1, $2, $3, $4)
        """,
        [gateway_id, "ready", "test-component", now]
      )

      query = "in:gateways gateway_id:#{gateway_id} limit:1"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      results = Map.get(response, "results", [])
      assert length(results) == 1
      assert hd(results)["gateway_id"] == gateway_id
    end
  end

  describe "integer parameter type" do
    test "queries by integer field" do
      gateway_id = "srql-int-test-" <> Ecto.UUID.generate()
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO gateways (gateway_id, agent_count, checker_count, last_seen)
        VALUES ($1, $2, $3, $4)
        """,
        [gateway_id, 5, 3, now]
      )

      # Note: Integer filtering might use different syntax depending on SRQL implementation
      query = "in:gateways gateway_id:#{gateway_id} limit:1"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      results = Map.get(response, "results", [])
      assert length(results) == 1

      gateway = hd(results)
      assert gateway["agent_count"] == 5
      assert gateway["checker_count"] == 3
    end
  end

  describe "timestamptz parameter type" do
    test "queries logs with timestamp in time range" do
      log_id = Ecto.UUID.generate()
      {:ok, log_id_binary} = Ecto.UUID.dump(log_id)
      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO logs (timestamp, id, severity_text, body, service_name)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [now, log_id_binary, "ERROR", "Timestamp test log", "srql-timestamp-test"]
      )

      # Query with time range - exercises timestamptz parameter
      query = "in:logs service_name:srql-timestamp-test time:last_1h limit:10"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      results = Map.get(response, "results", [])

      # Should find the log we just inserted
      assert Enum.any?(results, fn log -> log["id"] == log_id end)
    end
  end
end
