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

  test "Endpoint serves /assets/rum bundle with CORS, Timing-Allow-Origin, and Cache headers" do
    # Exercise live ServiceRadarWebNGWeb.Endpoint.call/2 dispatch for static assets.
    app_static_conn =
      :get
      |> conn("/images/integrations/armis.svg")
      |> ServiceRadarWebNGWeb.Endpoint.call([])

    assert app_static_conn.halted
    assert app_static_conn.status == 200

    stage_bundle_in_endpoint_static_dir!()

    rum_conn =
      :get
      |> conn("/assets/rum/boomerang-sr.min.js")
      |> ServiceRadarWebNGWeb.Endpoint.call(ServiceRadarWebNGWeb.Endpoint.init([]))

    assert rum_conn.halted
    assert rum_conn.status == 200
    assert rum_conn.resp_body =~ "ServiceRadarTrace"
    assert Plug.Conn.get_resp_header(rum_conn, "access-control-allow-origin") == ["*"]
    assert Plug.Conn.get_resp_header(rum_conn, "timing-allow-origin") == ["*"]

    assert Plug.Conn.get_resp_header(rum_conn, "cache-control") == [
             "public, max-age=300, stale-while-revalidate=86400"
           ]
  end

  defp stage_bundle_in_endpoint_static_dir! do
    rum_dir = Application.app_dir(:serviceradar_web_ng, "priv/static/assets/rum")
    target = Path.join(rum_dir, "boomerang-sr.min.js")

    if !File.exists?(target) do
      created_dir? = not File.dir?(rum_dir)
      File.mkdir_p!(rum_dir)
      File.cp!(resolve_bundle_path(), target)

      on_exit(fn ->
        File.rm(target)
        if created_dir?, do: File.rmdir(rum_dir)
      end)
    end
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
