defmodule ServiceRadarWebNG.ControlPlaneRuntimeAccess do
  @moduledoc """
  Validates the private listener's installed authentication purposes.

  Media identity comes from infrastructure configuration loaded at boot. It is
  this process's identity, not a database scope or provider authorization.
  """

  @doc "Whether the private listener has at least one usable authentication purpose."
  def enabled? do
    valid_token?(runtime_token(), runtime_token()) or match?({:ok, _, _}, media_installation())
  end

  @doc "Authenticates one purpose and returns only its installed identity."
  def authenticate(:account, token, nil) do
    if valid_token?(runtime_token(), token), do: {:ok, nil}, else: :error
  end

  def authenticate(:media, token, {reference, generation_header}) do
    with {:ok, expected_token, %{deployment_ref: ^reference, generation: generation} = installation} <-
           media_installation(),
         true <- generation_header == Integer.to_string(generation),
         true <- valid_token?(expected_token, token) do
      {:ok, installation}
    else
      _invalid_authentication -> :error
    end
  end

  defp media_installation do
    config =
      :serviceradar_web_ng
      |> Application.get_env(:control_plane_runtime, [])
      |> Keyword.get(:media, [])

    token = Keyword.get(config, :token)
    reference = Keyword.get(config, :deployment_ref)

    with true <- valid_token?(token, token),
         false <- valid_token?(runtime_token(), token),
         true <- is_binary(reference) and byte_size(reference) == 36,
         {:ok, ^reference} <- Ecto.UUID.cast(reference),
         {:ok, generation} <- generation(Keyword.get(config, :generation)) do
      {:ok, token, %{deployment_ref: reference, generation: generation}}
    else
      _invalid_installation -> :error
    end
  end

  defp generation(value) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 ->
        if Integer.to_string(number) == value, do: {:ok, number}, else: :error

      _invalid_generation ->
        :error
    end
  end

  defp generation(_value), do: :error

  defp runtime_token do
    :serviceradar_web_ng
    |> Application.get_env(:control_plane_runtime, [])
    |> Keyword.get(:token)
  end

  defp valid_token?(expected_token, presented_token)
       when is_binary(expected_token) and byte_size(expected_token) >= 32 and is_binary(presented_token) and
              byte_size(presented_token) <= 512 do
    expected_digest = :crypto.hash(:sha256, expected_token)
    presented_digest = :crypto.hash(:sha256, presented_token)

    Plug.Crypto.secure_compare(expected_digest, presented_digest)
  end

  defp valid_token?(_expected_token, _presented_token), do: false
end
