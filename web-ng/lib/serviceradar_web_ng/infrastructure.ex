defmodule ServiceRadarWebNG.Infrastructure do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadarWebNG.Infrastructure.Poller
  alias ServiceRadarWebNG.Repo

  def list_pollers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from(p in Poller,
        order_by: [desc: p.last_seen],
        limit: ^limit,
        offset: ^offset
      )
    )
  end
end
