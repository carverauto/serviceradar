defmodule ServiceRadarWebNGWeb.ApiQueryControllerPropertyTest do
  # Mutates global application env (`:srql_module`), so cannot be async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ServiceRadarWebNG.Generators.SRQLGenerators
  alias ServiceRadarWebNG.TestSupport.PropertyOpts
  alias ServiceRadarWebNG.TestSupport.SRQLStub

  setup do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, SRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    :ok
  end

  property "QueryController.execute/2 never crashes for JSON-like maps" do
    check all(
            payload <- SRQLGenerators.json_map(),
            max_runs: PropertyOpts.max_runs()
          ) do
      conn = Plug.Test.conn("POST", "/api/query")
      conn = ServiceRadarWebNGWeb.Api.QueryController.execute(conn, payload)
      assert conn.status in [200, 400]
    end
  end

  property "JSON parser does not crash on malformed JSON bodies" do
    invalid_json =
      [max_length: 8]
      |> SRQLGenerators.json_map()
      |> StreamData.map(fn payload -> Jason.encode!(payload) <> "x" end)

    check all(
            body <- invalid_json,
            max_runs: PropertyOpts.max_runs(:slow_property)
          ) do
      conn =
        "POST"
        |> Plug.Test.conn("/api/query", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> ServiceRadarWebNGWeb.Endpoint.call([])

      assert conn.status == 400
    end
  end
end
