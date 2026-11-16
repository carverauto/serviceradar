defmodule ServiceRadar.Camera.ArchiveDestination do
  @moduledoc """
  Version 1 and version 2 input for an immutable recording archive destination.

  Version 1 fixes `namespace` to `"recordings/v1"`. Version 2 carries an
  operator-selected key prefix (`1..128` bytes of `[a-z0-9/_-]`, no leading or
  trailing slash, no empty segment) in `namespace` and includes it in
  `destination_sha256`.

  This validates bounded metadata only. It performs no DNS, storage, custody or
  readiness operations. Credentials and qualification evidence belong outside
  this identity; accepting the input never enables recording or upload.
  """

  @fields [
    :schema_version,
    :provisioning_ref,
    :generation,
    :purpose,
    :provider,
    :endpoint,
    :region,
    :bucket,
    :namespace,
    :archive_format_version,
    :required_encryption
  ]
  @keys Enum.map(@fields, &Atom.to_string/1)
  @max_generation 9_223_372_036_854_775_807
  @namespace_v2_error "must be 1..128 bytes of lowercase ASCII letters, digits, '/', '_' or '-', " <>
                        "with no leading or trailing '/' and no empty segment"

  @spec attributes(term()) :: {:ok, map()} | {:error, :invalid_archive_destination}
  def attributes(input) do
    case validate(input) do
      {:ok, attributes} -> {:ok, attributes}
      {:error, _reasons} -> {:error, :invalid_archive_destination}
    end
  end

  @spec validate(term()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def validate(input) when is_map(input) do
    if map_size(input) != length(@fields) or Enum.sort(Map.keys(input)) != Enum.sort(@keys) do
      {:error, [{:destination, "archive destination must provide the exact required fields"}]}
    else
      errors = field_errors(input)

      if errors == [] do
        {:ok, build_attributes(input)}
      else
        {:error, errors}
      end
    end
  end

  def validate(_), do: {:error, [{:destination, "invalid archive destination"}]}

  defp build_attributes(input) do
    ordered = Enum.map(@fields, &{Atom.to_string(&1), Map.fetch!(input, Atom.to_string(&1))})
    bytes = ordered |> Jason.OrderedObject.new() |> Jason.encode!()
    hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    attributes = Map.new(@fields, &{&1, Map.fetch!(input, Atom.to_string(&1))})
    Map.put(attributes, :destination_sha256, hash)
  end

  defp field_errors(input) do
    schema_version = input["schema_version"]

    []
    |> check_field(schema_version in [1, 2], :schema_version, "must be 1 or 2")
    |> check_field(
      token?(input["provisioning_ref"]),
      :provisioning_ref,
      "must be 1..128 ASCII identifier characters"
    )
    |> check_field(
      is_integer(input["generation"]) and input["generation"] in 1..@max_generation,
      :generation,
      "must be a positive integer"
    )
    |> check_field(input["purpose"] == "recording", :purpose, "must be recording")
    |> check_field(input["provider"] == "s3_compatible", :provider, "must be s3_compatible")
    |> check_field(
      endpoint?(input["endpoint"]),
      :endpoint,
      "must be https://<dns-name> on port 443 with no path, query, fragment, or IP literal"
    )
    |> check_field(
      region?(input["region"]),
      :region,
      "must be 1..40 lowercase ASCII letters, digits, or hyphens"
    )
    |> check_field(
      dns_name?(input["bucket"], 3, 63),
      :bucket,
      "must be a 3..63 character DNS bucket name"
    )
    |> check_namespace(schema_version, input["namespace"])
    |> check_field(
      input["archive_format_version"] == 1,
      :archive_format_version,
      "must be 1"
    )
    |> check_field(
      input["required_encryption"] == "sse_s3_aes256",
      :required_encryption,
      "must be sse_s3_aes256"
    )
    |> Enum.reverse()
  end

  defp check_field(errors, true, _field, _message), do: errors
  defp check_field(errors, false, field, message), do: [{field, message} | errors]

  defp check_namespace(errors, 1, "recordings/v1"), do: errors

  defp check_namespace(errors, 1, _),
    do: [{:namespace, "must be recordings/v1 for schema version 1"} | errors]

  defp check_namespace(errors, 2, value) do
    if namespace_v2?(value) do
      errors
    else
      [{:namespace, @namespace_v2_error} | errors]
    end
  end

  defp check_namespace(errors, _other_version, _value), do: errors

  @doc false
  def namespace_v2?(value) when is_binary(value) do
    byte_size(value) in 1..128 and Regex.match?(~r/\A[a-z0-9_-]+(?:\/[a-z0-9_-]+)*\z/, value)
  end

  def namespace_v2?(_), do: false

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
