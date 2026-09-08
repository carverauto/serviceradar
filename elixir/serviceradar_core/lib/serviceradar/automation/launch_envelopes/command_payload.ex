defmodule ServiceRadar.Automation.LaunchEnvelopes.CommandPayload do
  @moduledoc """
  The deliberately minimal persisted AgentCommand payload for launch secrets.

  No launch coordinates or bearer material are accepted here. Those values are
  authenticated inside the encrypted envelope and looked up by the resolver.
  """

  @key "launch_envelope_ref"

  @spec build(binary()) :: {:ok, map()} | {:error, :invalid_launch_envelope_reference}
  def build(reference) when is_binary(reference) do
    if valid_reference?(reference),
      do: {:ok, %{@key => reference}},
      else: {:error, :invalid_launch_envelope_reference}
  end

  def build(_reference), do: {:error, :invalid_launch_envelope_reference}

  @spec parse(map()) :: {:ok, binary()} | {:error, :invalid_launch_envelope_payload}
  def parse(%{@key => reference} = payload) when map_size(payload) == 1 do
    if valid_reference?(reference),
      do: {:ok, reference},
      else: {:error, :invalid_launch_envelope_payload}
  end

  def parse(_payload), do: {:error, :invalid_launch_envelope_payload}

  defp valid_reference?("srle1_" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == 32
      _ -> false
    end
  end

  defp valid_reference?(_reference), do: false
end
