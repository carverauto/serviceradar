defmodule ServiceRadar.Credentials.SshPrivateKeyCredential do
  @moduledoc """
  Builds encrypted network credential secret attributes for SSH private keys.

  The returned map is intended for
  `ServiceRadar.Credentials.NetworkCredentialSecret.create_secret/2`. The
  private key and optional passphrase are encoded into `secret_payload`, which
  is encrypted by AshCloak on the resource. Public callers only receive the
  non-secret fingerprint and rotation metadata.
  """

  @type attrs :: %{
          required(:name) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:provider) => String.t(),
          optional(:username) => String.t() | nil,
          required(:private_key) => String.t(),
          optional(:passphrase) => String.t() | nil,
          optional(:last_rotated_at) => DateTime.t() | nil,
          optional(:next_rotation_due_at) => DateTime.t() | nil,
          optional(:metadata) => map()
        }

  @spec build_attrs(attrs()) :: {:ok, map()} | {:error, atom()}
  def build_attrs(attrs) when is_map(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, private_key} <- required_private_key(attrs) do
      payload =
        %{
          "private_key" => private_key,
          "username" => string_value(attrs, :username)
        }
        |> put_optional(
          "passphrase",
          string_value(attrs, :passphrase)
        )
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok,
       %{
         name: name,
         description: string_value(attrs, :description),
         provider: string_value(attrs, :provider) || "ssh",
         credential_kind: :ssh_private_key,
         username: string_value(attrs, :username),
         public_fingerprint: fingerprint(private_key),
         secret_payload: Jason.encode!(payload),
         last_rotated_at: datetime_value(attrs, :last_rotated_at),
         next_rotation_due_at: datetime_value(attrs, :next_rotation_due_at),
         metadata: public_metadata(attrs)
       }}
    end
  end

  def build_attrs(_attrs), do: {:error, :invalid_attrs}

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(private_key) when is_binary(private_key) do
    private_key
    |> normalize_private_key()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64(padding: false)
    |> then(&"SHA256:#{&1}")
  end

  @spec redacted_fingerprint(String.t() | nil) :: String.t() | nil
  def redacted_fingerprint(nil), do: nil
  def redacted_fingerprint(""), do: nil

  def redacted_fingerprint(fingerprint) when is_binary(fingerprint) do
    case String.split(fingerprint, ":", parts: 2) do
      [prefix, value] when byte_size(value) > 16 ->
        "#{prefix}:#{String.slice(value, 0, 8)}...#{String.slice(value, -6, 6)}"

      _ ->
        fingerprint
    end
  end

  defp required_private_key(attrs) do
    with {:ok, private_key} <- required_string(attrs, :private_key),
         true <- ssh_private_key?(private_key) do
      {:ok, private_key}
    else
      false -> {:error, :invalid_private_key}
      other -> other
    end
  end

  defp required_string(attrs, key) do
    case string_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :"missing_#{key}"}
    end
  end

  defp string_value(attrs, key) do
    attrs
    |> value(key)
    |> case do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp datetime_value(attrs, key) do
    case value(attrs, key) do
      %DateTime{} = value -> value
      _ -> nil
    end
  end

  defp public_metadata(attrs) do
    attrs
    |> value(:metadata)
    |> case do
      metadata when is_map(metadata) -> sanitize_metadata(metadata)
      _ -> %{}
    end
    |> Map.put(
      "fingerprint_display",
      redacted_fingerprint(fingerprint(value(attrs, :private_key)))
    )
    |> Map.put("secret_payload_format", "ssh_private_key.v1")
  end

  defp sanitize_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn {key, raw_value}, acc ->
      key = to_string(key)

      if sensitive_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize_metadata_value(raw_value))
      end
    end)
  end

  defp sanitize_metadata_value(value) when is_map(value), do: sanitize_metadata(value)

  defp sanitize_metadata_value(value) when is_list(value),
    do: Enum.map(value, &sanitize_metadata_value/1)

  defp sanitize_metadata_value(value) when is_binary(value),
    do: redact_private_key_material(value)

  defp sanitize_metadata_value(value), do: value

  defp redact_private_key_material(value) do
    if ssh_private_key?(value), do: "REDACTED", else: value
  end

  defp sensitive_key?(key) do
    normalized = String.downcase(String.trim(key))

    Enum.any?(
      ["password", "passwd", "passphrase", "secret", "token", "credential", "private_key"],
      &String.contains?(normalized, &1)
    )
  end

  defp ssh_private_key?(value) when is_binary(value) do
    String.contains?(value, "-----BEGIN ") and String.contains?(value, " PRIVATE KEY-----")
  end

  defp ssh_private_key?(_value), do: false

  defp normalize_private_key(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
