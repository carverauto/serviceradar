defmodule ServiceRadarWebNG.Edge.NatsDeploymentStatusTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Edge.NatsDeploymentStatus

  @moduletag :db_free

  setup do
    previous_web = Application.get_env(:serviceradar_web_ng, :nats_url)
    previous_core = Application.get_env(:serviceradar, :nats_url)
    previous_web_key = Application.get_env(:serviceradar_web_ng, :nats_account_public_key)
    previous_core_key = Application.get_env(:serviceradar, :nats_account_public_key)

    Application.delete_env(:serviceradar_web_ng, :nats_url)
    Application.delete_env(:serviceradar, :nats_url)
    Application.delete_env(:serviceradar_web_ng, :nats_account_public_key)
    Application.delete_env(:serviceradar, :nats_account_public_key)

    on_exit(fn ->
      restore_env(:serviceradar_web_ng, :nats_url, previous_web)
      restore_env(:serviceradar, :nats_url, previous_core)
      restore_env(:serviceradar_web_ng, :nats_account_public_key, previous_web_key)
      restore_env(:serviceradar, :nats_account_public_key, previous_core_key)
    end)

    :ok
  end

  test "treats the web-ng NATS_URL as ready" do
    Application.put_env(:serviceradar_web_ng, :nats_url, "tls://serviceradar-nats:4222")

    assert NatsDeploymentStatus.current() == %{
             status: :ready,
             nats_url: "tls://serviceradar-nats:4222",
             account_public_key: nil
           }
  end

  test "falls back to the core nats_url key" do
    Application.put_env(:serviceradar, :nats_url, "nats://127.0.0.1:4222")

    assert %{status: :ready, nats_url: "nats://127.0.0.1:4222"} = NatsDeploymentStatus.current()
  end

  test "is not configured when neither app has a NATS URL" do
    assert NatsDeploymentStatus.current() == %{
             status: :not_configured,
             nats_url: nil,
             account_public_key: nil
           }
  end

  test "ignores blank NATS URLs" do
    Application.put_env(:serviceradar_web_ng, :nats_url, "   ")
    Application.put_env(:serviceradar, :nats_url, "")

    assert %{status: :not_configured, nats_url: nil} = NatsDeploymentStatus.current()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
