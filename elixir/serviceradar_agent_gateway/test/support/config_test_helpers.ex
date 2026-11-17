defmodule ServiceRadarAgentGateway.ConfigTestHelpers do
  @moduledoc """
  Own the gateway identity (`ServiceRadarAgentGateway.Config`) for one test.

  Config lives in a single global `:persistent_term`. The unit target runs the
  files with `elixir -r` and never starts the application, so nothing sets it
  for a test: a module whose code path reads `Config.gateway_id/0` must set it
  itself, and a module that writes it must put back what it found. Otherwise
  the module passes or fails depending on which modules the ExUnit seed ran
  before it.

  Call these only from `async: false` modules. An async module that writes the
  global races every other async module that reads it.
  """

  alias ServiceRadarAgentGateway.Config

  @doc """
  Sets the gateway identity for the calling test and restores the value it
  replaced, or its absence, when the test exits.
  """
  @spec put_config!(keyword()) :: :ok
  def put_config!(opts) do
    preserve_config!()
    Config.setup(opts)
  end

  @doc """
  Restores the gateway identity the calling test started with when it exits,
  whatever the test writes in between.
  """
  @spec preserve_config!() :: :ok
  def preserve_config! do
    previous = :persistent_term.get(Config, :missing)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)
  end

  defp restore(:missing) do
    :persistent_term.erase(Config)
    :ok
  end

  defp restore(config), do: :persistent_term.put(Config, config)
end
