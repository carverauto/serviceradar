defmodule ServiceRadarWebNGWeb.CameraArchiveAccess do
  @moduledoc "Fresh recording permission and scoped camera access shared by HTTP and LiveView."

  alias ServiceRadar.Camera.Source
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  @permissions ["devices.view", "devices.cameras.recordings.view"]

  def source(scope, source_id) do
    with {:ok, scope} <- authorize(scope),
         {:ok, source_id} <- cast_id(source_id),
         {:ok, source} <- read_source(scope, source_id) do
      {:ok, scope, source}
    end
  end

  def recording(scope, source_id, block_id) do
    with {:ok, scope} <- authorize(scope),
         {:ok, source_id} <- cast_id(source_id),
         {:ok, block_id} <- cast_id(block_id),
         {:ok, _source} <- read_source(scope, source_id) do
      {:ok, scope, source_id, block_id}
    end
  end

  defp authorize(%Scope{user: user} = scope) when not is_nil(user), do: RBAC.authorize_current(scope, @permissions)

  defp authorize(_), do: {:error, :unauthorized}

  defp read_source(scope, source_id) do
    with {:ok, source} <- Source |> Ash.Query.for_read(:by_id, %{id: source_id}) |> Ash.read_one(scope: scope) do
      if source, do: {:ok, source}, else: {:error, :recording_block_not_found}
    end
  end

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
