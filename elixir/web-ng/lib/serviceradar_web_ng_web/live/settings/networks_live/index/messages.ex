defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages do
  @moduledoc false

  alias ServiceRadar.SweepJobs.ObanSupport

  def sweep_group_save_message(true) do
    if ObanSupport.available?() do
      "Sweep group saved"
    else
      "Sweep group saved. Scheduling is deferred until the scheduler is available."
    end
  end

  def sweep_group_save_message(false), do: "Sweep group saved"

  def sweep_group_toggle_message(:enable) do
    if ObanSupport.available?() do
      "Sweep group enabled"
    else
      "Sweep group enabled. Scheduling is deferred until the scheduler is available."
    end
  end

  def sweep_group_toggle_message(:disable), do: "Sweep group disabled"
end
