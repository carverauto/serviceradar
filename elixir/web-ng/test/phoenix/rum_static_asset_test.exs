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

  test "ServiceRadarWebNGWeb.Endpoint mounts /assets/rum Plug.Static before root Plug.Static with CORS, Timing-Allow-Origin, and Cache headers" do
    headers = ServiceRadarWebNGWeb.Endpoint.rum_static_headers()

    assert headers == %{
             "access-control-allow-origin" => "*",
             "timing-allow-origin" => "*",
             "cache-control" => "public, max-age=300, stale-while-revalidate=86400"
           }

    endpoint_source =
      "../../lib/serviceradar_web_ng_web/endpoint.ex"
      |> Path.expand(__DIR__)
      |> File.read!()

    {:defmodule, _, [_, [do: {:__block__, _, statements}]]} =
      Code.string_to_quoted!(endpoint_source)

    static_plugs =
      Enum.flat_map(statements, fn
        {:plug, _, [{:__aliases__, _, [:Plug, :Static]}, opts]} when is_list(opts) -> [opts]
        _ -> []
      end)

    rum_index = Enum.find_index(static_plugs, &(Keyword.get(&1, :at) == "/assets/rum"))
    root_index = Enum.find_index(static_plugs, &(Keyword.get(&1, :at) == "/"))

    assert is_integer(rum_index)
    assert is_integer(root_index)
    assert rum_index < root_index

    rum_opts = Enum.at(static_plugs, rum_index)
    assert Keyword.get(rum_opts, :from) == {:serviceradar_web_ng, "priv/static/assets/rum"}

    # Exercise live ServiceRadarWebNGWeb.Endpoint.call/2 dispatch for static assets.
    app_static_conn =
      :get
      |> conn("/images/integrations/armis.svg")
      |> ServiceRadarWebNGWeb.Endpoint.call([])

    assert app_static_conn.halted
    assert app_static_conn.status == 200

    staged_rum_path =
      Application.app_dir(:serviceradar_web_ng, "priv/static/assets/rum/boomerang-sr.min.js")

    if File.exists?(staged_rum_path) do
      endpoint_conn =
        :get
        |> conn("/assets/rum/boomerang-sr.min.js")
        |> ServiceRadarWebNGWeb.Endpoint.call([])

      assert endpoint_conn.halted
      assert endpoint_conn.status == 200
      assert endpoint_conn.resp_body =~ "ServiceRadarTrace"
      assert Plug.Conn.get_resp_header(endpoint_conn, "access-control-allow-origin") == ["*"]
      assert Plug.Conn.get_resp_header(endpoint_conn, "timing-allow-origin") == ["*"]

      assert Plug.Conn.get_resp_header(endpoint_conn, "cache-control") == [
               "public, max-age=300, stale-while-revalidate=86400"
             ]
    end

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
