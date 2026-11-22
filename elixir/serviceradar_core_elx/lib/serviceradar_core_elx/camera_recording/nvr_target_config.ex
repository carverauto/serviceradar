defmodule ServiceRadarCoreElx.CameraRecording.NVRTargetConfig do
  @moduledoc """
  Resolves installed workload credentials and storage identity for an NVR member.

  Target endpoints, TLS paths, bearer tokens and per-member storage UUIDs come
  only from operator-mounted configuration files, never from request parameters
  or camera credentials. The document format is `ServiceRadarNVRClient.Members`.
  """

  alias ServiceRadarNVRClient.Config
  alias ServiceRadarNVRClient.Members

  @type resolved_target :: %{
          member: String.t(),
          storage_id: String.t(),
          client_config: Config.t()
        }

  @spec resolve(String.t(), keyword()) :: {:ok, resolved_target()} | {:error, atom()}
  def resolve(member, opts \\ [])

  def resolve(member, opts) when is_binary(member) and is_list(opts) do
    with true <- Members.valid_name?(member) || {:error, :invalid_nvr_member},
         {:ok, config_path, token_path} <- config_paths(opts),
         {:ok, members} <- Members.load(config_path, token_path) do
      case Map.fetch(members, member) do
        {:ok, target} -> {:ok, target}
        :error -> {:error, :unknown_nvr_member}
      end
    end
  end

  def resolve(_member, _opts), do: {:error, :invalid_nvr_member}

  defp config_paths(opts) do
    config_file =
      Keyword.get_lazy(opts, :config_file, fn ->
        Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
      end)

    token_file =
      Keyword.get_lazy(opts, :token_file, fn ->
        Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)
      end)

    case {config_file, token_file} do
      {cfg, tok} when cfg in [nil, ""] and tok in [nil, ""] ->
        {:error, :nvr_client_not_configured}

      {cfg, tok} when is_binary(cfg) and is_binary(tok) ->
        if Path.type(cfg) == :absolute and Path.type(tok) == :absolute do
          {:ok, cfg, tok}
        else
          {:error, :invalid_nvr_client_config}
        end

      _ ->
        {:error, :invalid_nvr_client_config}
    end
  end
end
