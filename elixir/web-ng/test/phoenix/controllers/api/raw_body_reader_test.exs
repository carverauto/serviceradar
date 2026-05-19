defmodule ServiceRadarWebNGWeb.Api.RawBodyReaderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Api.RawBodyReader

  test "captures exact northbound callback body bytes" do
    body = ~s({"status":"succeeded","result":{"message":"ok"}})
    conn = Plug.Test.conn("POST", "/api/northbound/action-callbacks/job-1", body)

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == body
  end

  test "does not retain raw bodies for unrelated API paths" do
    conn = Plug.Test.conn("POST", "/api/other", ~s({"status":"ignored"}))

    assert {:ok, _body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == ""
  end
end
