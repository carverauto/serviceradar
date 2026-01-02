defmodule ServiceRadar.NATS.Creds do
  @moduledoc """
  Parses NATS .creds files to extract JWT and NKEY seed values.
  """

  @jwt_label "NATS USER JWT"
  @seed_label "USER NKEY SEED"

  @spec read(String.t()) :: {:ok, %{jwt: String.t(), nkey_seed: String.t()}} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, jwt} <- extract_block(content, @jwt_label),
         {:ok, seed} <- extract_block(content, @seed_label) do
      {:ok, %{jwt: jwt, nkey_seed: seed}}
    end
  end

  defp extract_block(content, label) do
    pattern = ~r/-+BEGIN #{Regex.escape(label)}-+\s*(.*?)\s*-+END #{Regex.escape(label)}-+/s

    case Regex.run(pattern, content, capture: :all_but_first) do
      [value] ->
        value = String.trim(value)

        if value == "" do
          {:error, {:empty_block, label}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:missing_block, label}}
    end
  end
end
