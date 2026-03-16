defmodule ServiceRadarWebNG.Web.Runtime do
  @moduledoc false

  @spec web_children() :: [module()]
  def web_children do
    apply(runtime_module(), :web_children, [])
  end

  @spec config_change(keyword(), [atom()]) :: :ok
  def config_change(changed, removed) do
    apply(runtime_module(), :config_change, [changed, removed])
  end

  defp runtime_module do
    Module.concat(["ServiceRadarWebNGWeb", "Runtime"])
  end
end
