defmodule ServiceRadar.Camera.ArchiveDestination do
  @moduledoc """
  Version 1 provisioning input for an immutable recording archive destination.

  This validates bounded metadata only. It performs no DNS, storage, custody or
  readiness operations. Credentials and qualification evidence belong outside
  this identity; accepting the input never enables recording or upload.
  """

  @fields ~w(schema_version provisioning_ref generation purpose provider endpoint region bucket namespace archive_format_version required_encryption)a
  @keys Enum.map(@fields, &Atom.to_string/1)
  @max_generation 9_223_372_036_854_775_807

  def attributes(
        %{
          "schema_version" => 1,
          "purpose" => "recording",
          "provider" => "s3_compatible",
          "namespace" => "recordings/v1",
          "archive_format_version" => 1,
          "required_encryption" => "sse_s3_aes256"
        } = input
      )
      when map_size(input) == length(@fields) do
    with true <- Enum.sort(Map.keys(input)) == Enum.sort(@keys),
         true <- token?(input["provisioning_ref"]),
         true <- is_integer(input["generation"]) and input["generation"] in 1..@max_generation,
         true <- endpoint?(input["endpoint"]),
         true <- region?(input["region"]),
         true <- dns_name?(input["bucket"], 3, 63) do
      ordered = Enum.map(@fields, &{Atom.to_string(&1), Map.fetch!(input, Atom.to_string(&1))})
      bytes = ordered |> Jason.OrderedObject.new() |> Jason.encode!()
      hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      attributes = Map.new(@fields, &{&1, Map.fetch!(input, Atom.to_string(&1))})
      {:ok, Map.put(attributes, :destination_sha256, hash)}
    else
      _ -> {:error, :invalid_archive_destination}
    end
  end

  def attributes(_), do: {:error, :invalid_archive_destination}

  defp token?(value) when is_binary(value),
    do: byte_size(value) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)

  defp token?(_), do: false

  defp region?(value) when is_binary(value),
    do: byte_size(value) in 1..40 and Regex.match?(~r/\A[a-z0-9-]+\z/, value)

  defp region?(_), do: false

  defp endpoint?(value) when is_binary(value) and byte_size(value) <= 261 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        userinfo: nil,
        path: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) ->
        value == "https://" <> host and dns_name?(host, 3, 253) and String.contains?(host, ".")

      _ ->
        false
    end
  end

  defp endpoint?(_), do: false

  defp dns_name?(value, minimum, maximum) when is_binary(value) do
    byte_size(value) in minimum..maximum and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, value) and
      not Enum.any?(["..", ".-", "-."], &String.contains?(value, &1)) and
      Enum.all?(String.split(value, "."), &(byte_size(&1) <= 63)) and
      match?({:error, _}, :inet.parse_address(String.to_charlist(value)))
  end

  defp dns_name?(_, _, _), do: false
end
