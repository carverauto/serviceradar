defmodule ServiceRadar.Security.SecurityEvent.Retention do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Security.SecurityEvent

  @spec run(DateTime.t()) :: {:ok, map()}
  def run(%DateTime{} = cutoff) do
    SecurityEvent
    |> Ash.Query.filter(expr(occurred_at < ^cutoff))
    |> Ash.bulk_destroy!(:destroy, %{}, return_records?: false)

    {:ok, %{deleted_at: DateTime.utc_now(), cutoff: cutoff}}
  end
end
