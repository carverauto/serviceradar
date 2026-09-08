defmodule ServiceRadarWebNG.AnsibleRepositories do
  @moduledoc """
  Scoped lifecycle operations for public Git playbook catalog repositories.
  """

  alias ServiceRadar.Automation.Ansible.GitCatalogSyncWorker
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.ConfigurationRequest

  require Ash.Query

  def list(scope, filters) do
    limit = Map.fetch!(filters, :limit)

    query =
      PlaybookRepository
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit + 1)
      |> after_cursor(filters[:after])

    with {:ok, repositories} <- Ash.read(query, scope: scope) do
      {items, remaining} = Enum.split(repositories, limit)
      next_cursor = if remaining != [], do: List.last(items).id
      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  def get(scope, id) do
    PlaybookRepository.get_by_id(id, scope: scope)
    |> require_record()
  end

  def create(scope, attrs) do
    PlaybookRepository.create_repository(attrs, scope: scope)
  end

  def update(scope, id, attrs, opts) do
    with {:ok, repository} <- get(scope, id) do
      repository
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> ConfigurationRequest.constrain(opts)
      |> Ash.update(scope: scope)
      |> ConfigurationRequest.normalize_result()
    end
  end

  def delete(scope, id, opts) do
    # The parent row lock also blocks new catalog rows acquiring their FK lock.
    # This keeps the empty-catalog check valid until the delete commits.
    Repo.transaction(fn ->
      with {:ok, repository} <- locked_repository(scope, id),
           :ok <- require_empty_catalog(scope, id),
           :ok <- destroy_repository(scope, repository, opts) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def sync(scope, id) do
    with {:ok, repository} <- get(scope, id),
         {:ok, job} <- GitCatalogSyncWorker.ensure_scheduled(repository.id) do
      state = if job == :already_scheduled, do: :already_scheduled, else: :scheduled
      {:ok, %{repository: repository, scheduling_status: state}}
    end
  end

  defp locked_repository(scope, id) do
    PlaybookRepository
    |> Ash.Query.for_read(:by_id, %{id: id}, scope: scope)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(scope: scope)
    |> require_record()
  end

  defp require_empty_catalog(scope, id) do
    query =
      Playbook
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(repository_id == ^id)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :repository_in_use}
      {:error, reason} -> {:error, reason}
    end
  end

  defp destroy_repository(scope, repository, opts) do
    repository
    |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope)
    |> ConfigurationRequest.constrain(opts)
    |> Ash.destroy(scope: scope)
    |> ConfigurationRequest.normalize_result()
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: Ash.Query.filter(query, id > ^cursor)

  defp require_record({:ok, nil}), do: {:error, :not_found}
  defp require_record({:error, %Ash.Error.Query.NotFound{}}), do: {:error, :not_found}
  defp require_record(result), do: result
end
