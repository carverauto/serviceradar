defmodule ServiceRadarCoreElx.ApplicationTest do
  use ExUnit.Case, async: false

  test "fails closed when media ingress certs are missing" do
    cert_dir = unique_tmp_dir!("core-elx-app-test")
    previous_dir = Application.get_env(:serviceradar_core_elx, :core_elx_media_cert_dir)
    previous_basename = Application.get_env(:serviceradar_core_elx, :core_elx_media_cert_basename)

    Application.put_env(:serviceradar_core_elx, :core_elx_media_cert_dir, cert_dir)
    Application.put_env(:serviceradar_core_elx, :core_elx_media_cert_basename, "core")

    on_exit(fn ->
      restore_env(:core_elx_media_cert_dir, previous_dir)
      restore_env(:core_elx_media_cert_basename, previous_basename)
      File.rm_rf(cert_dir)
    end)

    assert_raise RuntimeError, ~r/No mTLS certs available/, fn ->
      ServiceRadarCoreElx.Application.media_grpc_credential!()
    end
  end

  test "uses the shared core certificate basename for media ingress" do
    cert_dir = unique_tmp_dir!("core-elx-app-cert-test")
    previous_dir = Application.get_env(:serviceradar_core_elx, :core_elx_media_cert_dir)
    previous_basename = Application.get_env(:serviceradar_core_elx, :core_elx_media_cert_basename)

    File.write!(Path.join(cert_dir, "core.pem"), "cert")
    File.write!(Path.join(cert_dir, "core-key.pem"), "key")
    File.write!(Path.join(cert_dir, "root.pem"), "ca")

    Application.put_env(:serviceradar_core_elx, :core_elx_media_cert_dir, cert_dir)
    Application.put_env(:serviceradar_core_elx, :core_elx_media_cert_basename, "core")

    on_exit(fn ->
      restore_env(:core_elx_media_cert_dir, previous_dir)
      restore_env(:core_elx_media_cert_basename, previous_basename)
      File.rm_rf(cert_dir)
    end)

    assert %GRPC.Credential{} = ServiceRadarCoreElx.Application.media_grpc_credential!()
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
