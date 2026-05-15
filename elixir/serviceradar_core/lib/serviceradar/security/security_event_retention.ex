defmodule ServiceRadar.Security.SecurityEvent.Retention do
  @moduledoc false

  import Ash.Expr

  alias ServiceRadar.Security.SecurityEvent

  require Ash.Query

  @spec run(DateTime.t(), keyword()) :: {:ok, map()}
  def run(%DateTime{} = cutoff, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    SecurityEvent
    |> Ash.Query.filter(expr(occurred_at < ^cutoff))
    |> Ash.bulk_destroy!(:destroy, %{},
      actor: actor,
      return_records?: false,
      return_errors?: true
    )

    {:ok, %{deleted_at: DateTime.utc_now(), cutoff: cutoff}}
  end
end
