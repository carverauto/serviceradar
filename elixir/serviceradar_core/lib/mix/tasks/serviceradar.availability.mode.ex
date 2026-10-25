defmodule Mix.Tasks.Serviceradar.Availability.Mode do
  @shortdoc "Switch the merged availability mode (legacy, shadow, cutover)"

  @moduledoc """
  Switches `inventory.availability_mode` (`add-merged-device-availability`).

      mix serviceradar.availability.mode shadow
      mix serviceradar.availability.mode cutover
      mix serviceradar.availability.mode legacy

  `shadow` enqueues one full resolution of every device and the compatibility-table
  seed, and starts the expiry window; repeating it only enqueues the full pass again.
  `cutover` (from `shadow`) seeds the compatibility table under the drained switch and
  enqueues the reconciliation, which moves the mode to `authoritative` when done.
  `legacy` is the rollback from any mode; from `cutover` or `authoritative` it also
  restores `is_available` from the compatibility table. Each also sets the mode control
  that keeps the mode there (`legacy` holds legacy, `shadow` holds shadow, `cutover`
  returns to automatic), so the automatic progression does not undo it. No switch is
  needed to roll out merged availability: core progresses by itself. See
  `ServiceRadar.Inventory.Availability.Operator`.

  On a deployment, use the release instead:
  `bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.switch("shadow")'`.
  """

  use Mix.Task

  alias ServiceRadar.Inventory.Availability.Operator

  @impl true
  def run([mode]) when mode in ["shadow", "cutover", "legacy"] do
    Mix.Task.run("app.config")

    case Operator.switch(mode) do
      {:ok, _switched} -> :ok
      {:error, reason} -> Mix.raise("availability mode switch failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix serviceradar.availability.mode shadow|cutover|legacy")
end
