defmodule ServiceRadarAgentGateway.ConfigTest do
  @moduledoc """
  Tests for agent gateway configuration enforcement.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.Config

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  setup do
    previous = Application.get_env(:serviceradar_core, :platform_tenant_slug)
    Application.put_env(:serviceradar_core, :platform_tenant_slug, "platform")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :platform_tenant_slug)
      else
        Application.put_env(:serviceradar_core, :platform_tenant_slug, previous)
      end
    end)

    :ok
  end

  test "rejects zero UUID tenant id" do
    assert_raise RuntimeError, ~r/zero UUID/, fn ->
      Config.init(partition_id: "default", gateway_id: "gw-1", domain: "default", tenant_id: @zero_uuid)
    end
  end

  test "defaults tenant slug to platform slug when missing" do
    {:ok, config} =
      Config.init(
        partition_id: "default",
        gateway_id: "gw-1",
        domain: "default",
        tenant_id: Ash.UUID.generate()
      )

    assert config.tenant_slug == "platform"
  end

  test "uses platform tenant id env when gateway tenant id is unset" do
    platform_id = Ash.UUID.generate()

    with_env("SERVICERADAR_PLATFORM_TENANT_ID", platform_id, fn ->
      {:ok, config} =
        Config.init(
          partition_id: "default",
          gateway_id: "gw-1",
          domain: "default"
        )

      assert config.tenant_id == platform_id
    end)
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if is_nil(previous), do: System.delete_env(key), else: System.put_env(key, previous)
    end
  end
end
