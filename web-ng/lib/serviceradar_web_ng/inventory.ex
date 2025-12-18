defmodule ServiceRadarWebNG.Inventory do
  import Ecto.Query, only: [from: 2]

  alias ServiceRadarWebNG.Inventory.Device
  alias ServiceRadarWebNG.Repo

  def list_devices(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from(d in Device,
        order_by: [desc: d.last_seen_time],
        limit: ^limit,
        offset: ^offset
      )
    )
  end
end
