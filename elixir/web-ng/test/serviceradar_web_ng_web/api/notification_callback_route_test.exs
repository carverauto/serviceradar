defmodule ServiceRadarWebNGWeb.Api.NotificationCallbackRouteTest do
  @moduledoc """
  That the callback routes are actually raw-body buffered (task 4.3.0b).

  `RawBodyReader` buffers notification callbacks two ways: `buffered?/1`
  matches the `/api/notifications/callbacks/` prefix on the raw `request_path`,
  and `NotificationCallbackBody.callback?/1` matches the URI-decoded `path_info`
  segments, so percent-encoded spellings of the callback path get the same 1 MiB
  envelope and exact raw-byte retention for per-provider signature verification.
  An unbuffered route does not fail loudly: the verifier is handed `""`,
  computes a signature over the empty string, and answers an ordinary 401 -
  indistinguishable from a wrong secret. So the concrete paths are asserted here
  rather than the prefix list being eyeballed.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNGWeb.Api.RawBodyReader
  alias ServiceRadarWebNGWeb.Plugs.SafeParsers

  # web-ng's Bazel tier runs `ExUnit.configure(exclude: [:test], include: [:db_free])`,
  # so an untagged file runs ZERO tests in CI while reporting success. These need no
  # database - that is the point of the tag, not a workaround for one.
  @moduletag :db_free

  @providers ["slack"]

  test "notification callbacks reject oversized bodies before decoding across route representations" do
    bodies = [
      {"application/x-www-form-urlencoded", URI.encode_query(%{"payload" => String.duplicate("x", 1_048_577)})},
      {"application/json", Jason.encode!(%{"padding" => String.duplicate("x", 1_048_577)})},
      {"multipart/form-data; boundary=synthetic-boundary",
       "--synthetic-boundary\r\nContent-Disposition: form-data; name=\"payload\"\r\n\r\n" <>
         String.duplicate("x", 1_048_577) <> "\r\n--synthetic-boundary--\r\n"}
    ]

    for path <- [
          "/api/notifications/callbacks/slack",
          "/api/notifications/callbacks/pagerduty",
          "/%61pi/notifications/%63allbacks/slack"
        ],
        method <- [:post, :put],
        {content_type, body} <- bodies do
      parsed =
        method
        |> conn(path, body)
        |> put_req_header("content-type", content_type)
        |> SafeParsers.call(parser_opts())

      assert parsed.halted
      assert parsed.status == 400
      assert Jason.decode!(parsed.resp_body) == %{"error" => "malformed_request"}
    end
  end

  test "raw notification bytes remain bounded across multiple reads without truncation" do
    for path <- ["/api/notifications/callbacks/slack", "/%61pi/notifications/callbacks/slack"] do
      body = String.duplicate("x", 1_048_576)
      conn = conn(:post, path, body)
      assert {:more, _first, conn} = RawBodyReader.read_body(conn, length: 524_288)
      assert {:ok, _second, conn} = RawBodyReader.read_body(conn, length: 524_288)
      assert RawBodyReader.raw_body(conn) == body

      conn = conn(:post, path, body <> "x")
      assert {:more, _first, conn} = RawBodyReader.read_body(conn, length: 524_288)
      assert {:more, _second, conn} = RawBodyReader.read_body(conn, length: 524_288)

      assert_raise Plug.Parsers.RequestTooLargeError, fn -> RawBodyReader.read_body(conn, []) end
    end
  end

  test "multipart callbacks reject empty-part framing that does not consume the parser body budget" do
    body =
      String.duplicate("--synthetic-boundary\r\n\r\n\r\n", 50_000) <>
        "--synthetic-boundary--\r\n"

    parsed =
      :post
      |> conn("/api/notifications/callbacks/slack", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=synthetic-boundary")
      |> SafeParsers.call(parser_opts())

    assert parsed.halted
    assert parsed.status == 400
  end

  test "bounded callbacks keep exact signature bytes and unrelated uploads keep their larger limit" do
    for {path, content_type, body, expected} <- [
          {"/api/notifications/callbacks/slack", "application/x-www-form-urlencoded",
           "payload=" <> String.duplicate("x", 1_048_568), %{"payload" => String.duplicate("x", 1_048_568)}},
          {"/api/notifications/callbacks/pagerduty", "application/json",
           ~s({ "event" : {} }) <> String.duplicate(" ", 1_048_560), %{"event" => %{}}},
          {"/api/northbound/action-callbacks/example-job", "application/json",
           Jason.encode!(%{"padding" => String.duplicate("x", 1_048_577)}),
           %{"padding" => String.duplicate("x", 1_048_577)}},
          {"/api/plugin-packages/example/blob", "application/json",
           Jason.encode!(%{"padding" => String.duplicate("x", 1_048_577)}),
           %{"padding" => String.duplicate("x", 1_048_577)}}
        ] do
      parsed =
        :post
        |> conn(path, body)
        |> put_req_header("content-type", content_type)
        |> SafeParsers.call(parser_opts())

      refute parsed.halted
      assert parsed.body_params == expected
      assert RawBodyReader.raw_body(parsed) == if(RawBodyReader.buffered?(path), do: body, else: "")
    end
  end

  defp parser_opts do
    SafeParsers.init(
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason,
      body_reader: {RawBodyReader, :read_body, []},
      length: 67_108_864
    )
  end

  test "every provider callback path is buffered" do
    for provider <- @providers do
      path = "/api/notifications/callbacks/" <> provider

      assert RawBodyReader.buffered?(path),
             "#{path} is not raw-body buffered; every signature check on it would fail"
    end
  end

  test "the bare callbacks path is NOT buffered, which is why routes carry a provider segment" do
    # `buffered?/1` is a raw `request_path` prefix check, and the registered
    # prefix ends in a slash, so it returns false for the bare path. That is why
    # routes carry a provider segment. The bare path is still bounded and its
    # exact raw bytes retained via `NotificationCallbackBody.callback?/1`, which
    # matches the URI-decoded `path_info` segments.
    refute RawBodyReader.buffered?("/api/notifications/callbacks")
  end

  test "the action-link routes are deliberately not buffered" do
    # They authorise with a capability token in the URL, not a signature over the
    # body, so they need no raw body and buffering them would retain request
    # bodies for no reason.
    refute RawBodyReader.buffered?("/api/notifications/actions/srn1.abc.def")
  end

  test "the northbound prefix is still buffered" do
    # This change adds a prefix; it must not have replaced one.
    assert RawBodyReader.buffered?("/api/northbound/action-callbacks/job-1")
  end
end
