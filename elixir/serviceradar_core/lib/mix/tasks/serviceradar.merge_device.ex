defmodule Mix.Tasks.Serviceradar.MergeDevice do
  @moduledoc """
  Merge a duplicate device into a canonical device.

  Usage:
    mix serviceradar.merge_device --from <duplicate_uid> --to <canonical_uid> [--reason <reason>]
  """

  use Mix.Task

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.IdentityReconciler

  @shortdoc "Merge a duplicate device into a canonical device"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [from: :string, to: :string, reason: :string]
      )

    from_id = opts[:from]
    to_id = opts[:to]
    reason = opts[:reason] || "manual_merge"

    if is_nil(from_id) or is_nil(to_id) do
      Mix.raise("Both --from and --to are required")
    end

    actor = SystemActor.system(:manual_device_merge)

    case IdentityReconciler.merge_devices(from_id, to_id, actor: actor, reason: reason) do
      :ok ->
        Mix.shell().info("Merged #{from_id} into #{to_id}")

      {:error, error} ->
        Mix.raise("Merge failed: #{inspect(error)}")
    end
  end
end
