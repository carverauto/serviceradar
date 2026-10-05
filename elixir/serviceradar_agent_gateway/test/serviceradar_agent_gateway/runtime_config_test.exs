defmodule ServiceRadarAgentGateway.RuntimeConfigTest do
  # Evaluates the gateway's release runtime.exs the way a prod boot does. Agents
  # download plugin Wasm from the URL in :plugin_storage :public_url; when the
  # operator-facing URL is unreachable from agents (an on-prem load balancer
  # without hairpin NAT), AGENT_PLUGIN_STORAGE_PUBLIC_URL must win, as it does
  # in web-ng.
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  @env_names ["AGENT_PLUGIN_STORAGE_PUBLIC_URL", "PLUGIN_STORAGE_PUBLIC_URL"]

  setup do
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  for {label, agent_url, public_url, expected} <- [
        {"prefers AGENT_PLUGIN_STORAGE_PUBLIC_URL", " https://agent-gateway.example.internal:50053 ",
         "https://serviceradar.example.com", "https://agent-gateway.example.internal:50053"},
        {"falls back to PLUGIN_STORAGE_PUBLIC_URL when the agent URL is blank", "", "https://serviceradar.example.com",
         "https://serviceradar.example.com"}
      ] do
    test "plugin storage public URL #{label}" do
      System.put_env("AGENT_PLUGIN_STORAGE_PUBLIC_URL", unquote(agent_url))
      System.put_env("PLUGIN_STORAGE_PUBLIC_URL", unquote(public_url))

      plugin_storage =
        @runtime_config
        |> Config.Reader.read!(env: :prod)
        |> get_in([:serviceradar_core, :plugin_storage])

      assert plugin_storage[:public_url] == unquote(expected)
    end
  end
end
