defmodule ServiceRadarAgentGateway.ApplicationTest do
  use ExUnit.Case, async: false

  test "fails closed when edge listener certs are missing" do
    cert_dir = unique_tmp_dir!("gateway-app-test")

    previous = Application.get_env(:serviceradar_agent_gateway, :gateway_cert_dir)
    Application.put_env(:serviceradar_agent_gateway, :gateway_cert_dir, cert_dir)

    on_exit(fn ->
      restore_env(:gateway_cert_dir, previous)
      File.rm_rf(cert_dir)
    end)

    assert_raise RuntimeError, ~r/No mTLS certs available/, fn ->
      ServiceRadarAgentGateway.Application.edge_server_ssl_opts!()
    end
  end

  defp unique_tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(dir)
    dir
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
