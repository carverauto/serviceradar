defmodule ServiceRadar.Edge.ReleaseArtifactDelivery do
  @moduledoc """
  Resolves gateway-served artifact delivery metadata for rollout targets.
  """

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.ReleaseArtifactMirror
  alias ServiceRadar.Infrastructure.Agent

  @blocked_statuses [:failed, :rolled_back, :canceled]
  @default_gateway_path "/artifacts/releases/download"

  @spec gateway_transport(AgentReleaseTarget.t(), AgentRelease.t(), Agent.t()) ::
          {:ok, map()} | {:error, term()}
  def gateway_transport(
        %AgentReleaseTarget{} = target,
        %AgentRelease{} = release,
        %Agent{} = agent
      ) do
    with {:ok, artifact} <- AgentReleaseManager.select_artifact_for_agent(release, agent),
         {:ok, mirrored} <- ReleaseArtifactMirror.mirrored_artifact(release, artifact) do
      {:ok,
       %{
         "kind" => "gateway_https",
         "path" => gateway_path(),
         "port" => gateway_port(),
         "target_id" => target.id,
         "file_name" => mirrored["file_name"]
       }}
    end
  end

  @spec resolve_download(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_download(target_id, command_id) do
    actor = ServiceRadar.Actors.SystemActor.system(:agent_release_artifact_download)

    with {:ok, %AgentReleaseTarget{} = target} <-
           AgentReleaseTarget.get_by_id(target_id, actor: actor),
         true <- authorized_target?(target, command_id),
         {:ok, %AgentRelease{} = release} <-
           AgentRelease.get_by_id(target.release_id, actor: actor),
         {:ok, %Agent{} = agent} <- Agent.get_by_uid(target.agent_id, actor: actor),
         {:ok, artifact} <- AgentReleaseManager.select_artifact_for_agent(release, agent),
         {:ok, mirrored} <- ReleaseArtifactMirror.mirrored_artifact(release, artifact) do
      {:ok,
       %{
         object_key: mirrored["object_key"],
         file_name: mirrored["file_name"],
         content_type: mirrored["content_type"],
         target_id: target.id,
         agent_id: target.agent_id
       }}
    else
      false -> {:error, :unauthorized}
      {:error, :artifact_not_mirrored} -> {:error, :artifact_not_mirrored}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  @spec gateway_port() :: pos_integer()
  def gateway_port do
    case "GATEWAY_ARTIFACT_PORT" |> System.get_env("50053") |> Integer.parse() do
      {port, ""} when port > 0 and port < 65_536 -> port
      _ -> 50_053
    end
  end

  @spec gateway_path() :: String.t()
  def gateway_path do
    "GATEWAY_ARTIFACT_PATH"
    |> System.get_env(@default_gateway_path)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_gateway_path
      "/" <> _path = path -> path
      path -> "/" <> path
    end
  end

  defp authorized_target?(%AgentReleaseTarget{} = target, command_id) do
    target.status not in @blocked_statuses and
      to_string(target.command_id || "") != "" and
      to_string(target.command_id) == to_string(command_id)
  end
end
