defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginServiceIdentity do
  @moduledoc false

  alias ServiceRadar.Repo

  # Naming contract: docs/docs/wasm-plugins.md. Keep the state/history
  # existence check: recomputing solely from enabled siblings would rename
  # a surviving assignment and split its existing series.
  @doc false
  @spec disambiguated_name(String.t(), String.t()) :: String.t()
  def disambiguated_name(package_name, assignment_id)
      when is_binary(package_name) and is_binary(assignment_id) do
    package_name <> "#" <> assignment_id
  end

  @doc false
  @spec service_name_for_assignment(String.t(), String.t()) ::
          {:ok, String.t()} | :not_found | {:error, term()}
  def service_name_for_assignment(agent_uid, assignment_id)
      when is_binary(agent_uid) and is_binary(assignment_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(assignment_id),
         {:ok, %{rows: [[package_name, primary?, suffixed?]]}} <-
           Repo.query(service_name_sql(), [String.trim(agent_uid), uuid]) do
      if suffixed? or not primary? do
        {:ok, disambiguated_name(package_name, uuid)}
      else
        {:ok, package_name}
      end
    else
      :error -> :not_found
      {:ok, %{rows: []}} -> :not_found
      {:error, _reason} = error -> error
    end
  end

  def service_name_for_assignment(_agent_uid, _assignment_id), do: :not_found

  defp service_name_sql do
    """
    WITH target AS (
      SELECT
        assignment.id,
        assignment.inserted_at,
        package.name AS package_name,
        package.plugin_id
      FROM platform.plugin_assignments AS assignment
      JOIN platform.plugin_packages AS package
        ON package.id =
          COALESCE(assignment.rollout_plugin_package_id, assignment.plugin_package_id)
      WHERE assignment.id = ($2::text)::uuid
        AND assignment.agent_uid = $1
    )
    SELECT
      target.package_name,
      NOT EXISTS (
        SELECT 1
        FROM platform.plugin_assignments AS sibling
        JOIN platform.plugin_packages AS sibling_package
          ON sibling_package.id =
            COALESCE(sibling.rollout_plugin_package_id, sibling.plugin_package_id)
        WHERE sibling.agent_uid = $1
          AND sibling.enabled
          AND sibling_package.plugin_id = target.plugin_id
          AND (sibling.inserted_at, sibling.id) < (target.inserted_at, target.id)
      ) AS primary_assignment,
      (
        EXISTS (
          SELECT 1
          FROM platform.service_state AS service_state
          WHERE service_state.agent_id = $1
            AND service_state.service_type = 'plugin'
            AND service_state.service_name =
              target.package_name || '#' || target.id::text
        )
        OR EXISTS (
          SELECT 1
          FROM platform.service_status AS service_status
          WHERE service_status.agent_id = $1
            AND service_status.service_type = 'plugin'
            AND service_status.service_name =
              target.package_name || '#' || target.id::text
        )
      ) AS has_disambiguated_history
    FROM target
    """
  end
end
