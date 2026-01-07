defmodule ServiceRadar.Oban.TenantSupervisor do
  @moduledoc """
  Dynamic supervisor for per-tenant Oban instances.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
