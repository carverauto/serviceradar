defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginAssignmentEligibility do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Repo

  @plugin_result_output "serviceradar.plugin_result.v1"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @streaming_plugin_capability "camera_media_stream"

  @doc false
  def apply_to_attrs(%{service_type: "plugin"} = attrs) do
    case eligible?(attrs) do
      {:ok, true} -> {:ok, attrs}
      {:ok, false} -> {:ok, %{attrs | state: "inactive"}}
      {:error, _reason} = error -> error
    end
  end

  def apply_to_attrs(attrs), do: {:ok, attrs}

  @doc false
  def eligible?(attrs) when is_map(attrs) do
    params = [
      Map.fetch!(attrs, :agent_id),
      Map.fetch!(attrs, :service_name),
      Map.get(attrs, :details),
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(eligible_query(), params) do
      {:ok, %{rows: [[eligible?]]}} when is_boolean(eligible?) -> {:ok, eligible?}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_assignment_eligibility_result, other}}
    end
  end

  def eligible?(_attrs), do: {:error, :invalid_plugin_assignment_eligibility_attrs}

  defp eligible_query do
    """
    SELECT EXISTS (
      SELECT 1
      FROM platform.plugin_assignments AS assignment
      JOIN platform.plugin_packages AS package
        ON package.id = assignment.plugin_package_id
      WHERE assignment.enabled = true
        AND package.status = 'approved'
        AND assignment.agent_uid = $1
        AND #{PluginStateContract.package_match_sql("$3::text", "$2", "package.name", "package.plugin_id")}
        AND (
          package.outputs IN ($4, $5)
          OR $6 = ANY(package.approved_capabilities)
          OR (
            coalesce(array_length(package.approved_capabilities, 1), 0) = 0
            AND package.manifest->'capabilities' ? $6
          )
        )
    )
    """
  end
end
