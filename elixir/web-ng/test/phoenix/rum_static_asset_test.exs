defmodule ServiceRadarWebNGWeb.RumStaticAssetTest do
  @moduledoc """
  DB-free contract tests verifying the offline-hermetic Boomerang RUM bundle
  artifact (`boomerang-sr.min.js`) and its CORS/Timing/Cache `Plug.Static` mount.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  @moduletag :db_free

  @max_bundle_bytes 262_144

  test "boomerang-sr.min.js bundle exists, fits budget, and includes ServiceRadarTrace" do
    bundle_path = resolve_bundle_path()
    assert File.exists?(bundle_path), "expected bundle at #{bundle_path}"

    body = File.read!(bundle_path)
    byte_len = byte_size(body)

    assert byte_len > 10_000, "boomerang-sr.min.js is unexpectedly small (#{byte_len} bytes)"
    assert byte_len <= @max_bundle_bytes, "boomerang-sr.min.js exceeded budget (#{byte_len} bytes)"
    assert body =~ "BOOMR"
    assert body =~ "ServiceRadarTrace"
    assert body =~ "traceparent"
    assert body =~ "servertiming"
    refute body =~ "%boomerang_version%"
    refute body =~ "BEGIN_DEBUG"
  end

  test "/assets/rum Plug.Static serves the bundle with CORS, Timing-Allow-Origin, and Cache headers" do
    headers = ServiceRadarWebNGWeb.Endpoint.rum_static_headers()

    assert headers == %{
             "access-control-allow-origin" => "*",
             "timing-allow-origin" => "*",
             "cache-control" => "public, max-age=300, stale-while-revalidate=86400"
           }

    # Exercise live ServiceRadarWebNGWeb.Endpoint.call/2 dispatch for static assets.
    app_static_conn =
      :get
      |> conn("/images/integrations/armis.svg")
      |> ServiceRadarWebNGWeb.Endpoint.call([])

    assert app_static_conn.halted
    assert app_static_conn.status == 200

    bundle_path = resolve_bundle_path()
    rum_dir = Path.dirname(bundle_path)

    opts =
      Plug.Static.init(
        at: "/assets/rum",
        from: rum_dir,
        gzip: false,
        headers: headers
      )

    static_conn =
      :get
      |> conn("/assets/rum/boomerang-sr.min.js")
      |> Plug.Static.call(opts)

    assert static_conn.halted
    assert static_conn.status == 200
    assert static_conn.resp_body =~ "ServiceRadarTrace"
    assert Plug.Conn.get_resp_header(static_conn, "access-control-allow-origin") == ["*"]
    assert Plug.Conn.get_resp_header(static_conn, "timing-allow-origin") == ["*"]

    assert Plug.Conn.get_resp_header(static_conn, "cache-control") == [
             "public, max-age=300, stale-while-revalidate=86400"
           ]
  end

  defp resolve_bundle_path do
    candidates = [
      Path.expand("../../assets/static/assets/rum/boomerang-sr.min.js", __DIR__),
      Path.expand("../../priv/static/assets/rum/boomerang-sr.min.js", __DIR__)
    ]

    Enum.find(candidates, &File.exists?/1) ||
      flunk(
        "boomerang-sr.min.js was not found in #{inspect(candidates)}; " <>
          "ensure //elixir/web-ng/assets:rum_bundle is declared in :unit_tests data"
      )
  end
end
