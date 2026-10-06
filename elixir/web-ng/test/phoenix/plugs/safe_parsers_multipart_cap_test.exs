defmodule ServiceRadarWebNGWeb.Plugs.SafeParsersMultipartCapTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNGWeb.Plugs.SafeParsers

  @moduletag :db_free

  @envelope 67_108_864
  @ordinary 8_388_608
  @boundary "synthetic"

  test "a normal multipart body still parses on a non-upload route" do
    conn = post_multipart("/devices", "ok")

    refute conn.halted
    assert conn.body_params["note"] == "ok"
  end

  test "multipart bodies on routes that do not take package uploads stop at the lower cap" do
    payload = :binary.copy("a", @ordinary)

    for path <- ["/api/v1/scans", "/devices", "/v1/field-survey/auth-check"] do
      conn = post_multipart(path, payload)

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body =~ "malformed_request"
    end
  end

  test "package upload routes accept a multipart body above the ordinary cap" do
    payload = :binary.copy("a", @ordinary)

    for path <- [
          "/api/v1/dashboard-packages",
          "/admin/plugins/new",
          "/settings/agents/plugins/pkg-1",
          "/settings/dashboards/packages"
        ] do
      conn = post_multipart(path, payload)

      refute conn.halted
      assert conn.body_params["note"] == payload
    end
  end

  test "json bodies keep the endpoint envelope" do
    parent = self()

    opts =
      SafeParsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {__MODULE__, :read_body, [parent]},
        length: @envelope
      )

    "POST"
    |> conn("/api/v1/scans", ~s({"scan":"synthetic"}))
    |> put_req_header("content-type", "application/json")
    |> SafeParsers.call(opts)

    assert_receive {:parser_length, @envelope}
  end

  def read_body(conn, opts, parent) do
    send(parent, {:parser_length, Keyword.get(opts, :length)})
    {:ok, "", conn}
  end

  defp post_multipart(path, payload) do
    opts =
      SafeParsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: @envelope
      )

    "POST"
    |> conn(path, multipart_body(payload))
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> SafeParsers.call(opts)
  end

  defp multipart_body(payload) do
    "--#{@boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"note\"\r\n" <>
      "\r\n" <>
      payload <>
      "\r\n--#{@boundary}--\r\n"
  end
end
