defmodule ServiceRadar.Analytics.StarRocks.LoadSupervisor do
  @moduledoc """
  Restarts admission and its HTTP workers together. An admission restart cannot
  forget outstanding requests and admit another full budget beside them.
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {ServiceRadar.Analytics.StarRocks.LoadAdmission, opts},
        {Task.Supervisor, name: ServiceRadar.Analytics.StarRocks.LoadTasks}
      ],
      strategy: :rest_for_one
    )
  end
end
