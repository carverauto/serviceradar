defmodule ServiceRadar.Integrations.ArmisNorthboundObanReaper do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.SweepJobs.ObanSupport

  @spec reap_stale_source_jobs(
          module(),
          String.t() | Ecto.UUID.t(),
          DateTime.t() | NaiveDateTime.t(),
          pos_integer(),
          keyword()
        ) ::
          {non_neg_integer(), nil | [term()]}
  def reap_stale_source_jobs(worker, integration_source_id, now, cutoff_seconds, opts \\ []) do
    worker_name = inspect(worker)
    now = to_datetime(now)

    cutoff = DateTime.add(now, -cutoff_seconds, :second)

    support_module = Keyword.get(opts, :support_module, ObanSupport)
    prefix = support_module.prefix()

    Oban.Job
    |> where([j], j.worker == ^worker_name)
    |> where([j], j.state == "executing")
    |> where([j], not is_nil(j.attempted_at) and j.attempted_at < ^cutoff)
    |> where(
      [j],
      fragment("? ->> ? = ?", j.args, ^"integration_source_id", ^to_string(integration_source_id))
    )
    |> ServiceRadar.Repo.update_all([set: [state: "discarded", discarded_at: now]],
      prefix: prefix
    )
  rescue
    _ -> {0, nil}
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime

  defp to_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
end
