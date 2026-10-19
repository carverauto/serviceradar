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

  @filter_paths ["/topology/tiles/search", "/topology/details", "/topology/snapshot/latest", "/topology/query"]

  test "filtered topology reads keep their GET actions and accept a POST body above the request line" do
    query = String.duplicate("a", 12_000)
    body = Jason.encode!(%{"device_id" => "synthetic", "query" => query})
    assert byte_size(body) > 8_000 and byte_size(body) < 65_536

    opts =
      SafeParsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: @envelope
      )

    for path <- @filter_paths do
      get_route = Phoenix.Router.route_info(ServiceRadarWebNGWeb.Router, "GET", path, "localhost")
      post_route = Phoenix.Router.route_info(ServiceRadarWebNGWeb.Router, "POST", path, "localhost")
      assert %{plug: plug, plug_opts: action} = post_route

      case get_route do
        %{plug: ^plug, plug_opts: ^action} -> :ok
        :error -> assert path == "/topology/query"
      end

      conn =
        "POST"
        |> conn(path, body)
        |> put_req_header("content-type", "application/json")
        |> SafeParsers.call(opts)

      refute conn.halted
      assert conn.body_params["query"] == query
    end

    huge = Jason.encode!(%{"query" => String.duplicate("b", 70_000)})

    for path <- @filter_paths do
      conn =
        "POST"
        |> conn(path, huge)
        |> put_req_header("content-type", "application/json")
        |> SafeParsers.call(opts)

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body =~ "malformed_request"
    end
  end

  test "a trailing slash keeps the topology body cap" do
    query = String.duplicate("a", 12_000)
    body = Jason.encode!(%{"device_id" => "synthetic", "query" => query})
    assert byte_size(body) > 8_192 and byte_size(body) < 65_536

    opts =
      SafeParsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: 8_192
      )

    for path <- ["/topology/query", "/topology/query/"] do
      conn =
        "POST"
        |> conn(path, body)
        |> put_req_header("content-type", "application/json")
        |> SafeParsers.call(opts)

      refute conn.halted
      assert conn.body_params["query"] == query
    end

    huge = Jason.encode!(%{"query" => String.duplicate("b", 70_000)})

    for path <- ["/topology/query", "/topology/query/"] do
      conn =
        "POST"
        |> conn(path, huge)
        |> put_req_header("content-type", "application/json")
        |> SafeParsers.call(opts)

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body =~ "malformed_request"
    end
  end

  defp multipart_body(payload) do
    "--#{@boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"note\"\r\n" <>
      "\r\n" <>
      payload <>
      "\r\n--#{@boundary}--\r\n"
  end
end
