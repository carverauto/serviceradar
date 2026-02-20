defmodule ServiceRadarWebNGWeb.WasmAssetController do
  use ServiceRadarWebNGWeb, :controller

  def plain(conn, _params) do
    redirect(conn, to: "/assets/js/god_view_exec.wasm")
  end

  def hashed(conn, %{"digest" => digest}) do
    digest =
      digest
      |> to_string()
      |> String.trim()
      |> String.trim_trailing(".wasm")

    redirect(conn, to: "/assets/js/god_view_exec-#{digest}.wasm")
  end
end
