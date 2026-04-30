defmodule ServiceRadarWebNG.Plugins.CosignVerifier do
  @moduledoc """
  Verifies first-party Wasm plugin OCI artifacts with Cosign.
  """

  @type artifact :: %{required(:ref) => String.t(), required(:digest) => String.t()}

  @spec verify(artifact()) :: :ok | {:error, term()}
  def verify(%{ref: ref, digest: digest}) when is_binary(ref) and is_binary(digest) do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    case cosign_key_arg(config) do
      {:ok, key_arg, cleanup} ->
        try do
          binary = Keyword.get(config, :cosign_binary, "cosign")
          target = digest_ref(ref, digest)

          with {:ok, output} <- run_cosign(binary, key_arg, target) do
            verify_rekor_output(output)
          end
        after
          cleanup.()
        end

      {:error, _reason} = error ->
        error
    end
  end

  def verify(_artifact), do: {:error, :invalid_cosign_artifact}

  defp digest_ref(ref, digest) do
    ref
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.replace(~r/:[^\/:]+$/, "")
    |> then(&"#{&1}@#{digest}")
  end

  defp cosign_key_arg(config) do
    cond do
      key_file = Keyword.get(config, :cosign_public_key_file) ->
        {:ok, key_file, fn -> :ok end}

      key = Keyword.get(config, :cosign_public_key) ->
        path = Path.join(System.tmp_dir!(), "serviceradar-cosign-pub-#{System.unique_integer([:positive])}.pub")
        File.write!(path, key)
        {:ok, path, fn -> File.rm(path) end}

      true ->
        {:error, :cosign_public_key_not_configured}
    end
  end

  defp run_cosign(binary, key_arg, target) do
    case System.cmd(binary, ["verify", "--key", key_arg, target], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:cosign_verify_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:cosign_verify_failed, Exception.message(error)}}
  end

  defp verify_rekor_output(output) do
    if rekor_verified?(output) do
      :ok
    else
      {:error, :cosign_rekor_verification_missing}
    end
  end

  defp rekor_verified?(output) when is_binary(output) do
    output =~ "tlog entry verified" or output =~ "Bundle verified"
  end
end
