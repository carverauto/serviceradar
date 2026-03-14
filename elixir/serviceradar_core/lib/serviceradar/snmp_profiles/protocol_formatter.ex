defmodule ServiceRadar.SNMPProfiles.ProtocolFormatter do
  @moduledoc false

  @auth_protocols %{
    md5: %{compact: "MD5", hyphenated: "MD5"},
    sha: %{compact: "SHA", hyphenated: "SHA"},
    sha224: %{compact: "SHA224", hyphenated: "SHA-224"},
    sha256: %{compact: "SHA256", hyphenated: "SHA-256"},
    sha384: %{compact: "SHA384", hyphenated: "SHA-384"},
    sha512: %{compact: "SHA512", hyphenated: "SHA-512"}
  }

  @priv_protocols %{
    des: %{compact: "DES", hyphenated: "DES"},
    aes: %{compact: "AES", hyphenated: "AES"},
    aes192: %{compact: "AES192", hyphenated: "AES-192"},
    aes256: %{compact: "AES256", hyphenated: "AES-256"},
    aes192c: %{compact: "AES192", hyphenated: "AES-192-C"},
    aes256c: %{compact: "AES256", hyphenated: "AES-256-C"}
  }

  @security_levels %{
    no_auth_no_priv: "noAuthNoPriv",
    auth_no_priv: "authNoPriv",
    auth_priv: "authPriv"
  }

  @spec version(atom() | String.t() | nil, keyword()) :: String.t()
  def version(value, opts \\ []) do
    allow_binary? = Keyword.get(opts, :allow_binary?, false)

    case normalize_version(value) do
      nil when allow_binary? and is_binary(value) -> value
      nil -> "v2c"
      normalized -> Atom.to_string(normalized)
    end
  end

  @spec auth_protocol(atom() | String.t() | nil, keyword()) :: String.t() | nil
  def auth_protocol(value, opts \\ []) do
    format_protocol(value, @auth_protocols, opts)
  end

  @spec priv_protocol(atom() | String.t() | nil, keyword()) :: String.t() | nil
  def priv_protocol(value, opts \\ []) do
    format_protocol(value, @priv_protocols, opts)
  end

  @spec security_level(atom() | nil) :: String.t()
  def security_level(value) do
    value
    |> normalize_security_level()
    |> then(&Map.get(@security_levels, &1, "noAuthNoPriv"))
  end

  @spec normalize_version(atom() | String.t() | nil) :: atom() | nil
  def normalize_version(:v1), do: :v1
  def normalize_version(:v2c), do: :v2c
  def normalize_version(:v3), do: :v3
  def normalize_version(nil), do: nil

  def normalize_version(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "v1" -> :v1
      "v2c" -> :v2c
      "v3" -> :v3
      _ -> nil
    end
  end

  def normalize_version(_), do: nil

  @spec normalize_security_level(atom() | String.t() | nil) :: atom() | nil
  def normalize_security_level(value) when value in [:no_auth_no_priv, :auth_no_priv, :auth_priv],
    do: value

  def normalize_security_level(value) when is_binary(value) do
    case String.trim(value) do
      "noAuthNoPriv" -> :no_auth_no_priv
      "authNoPriv" -> :auth_no_priv
      "authPriv" -> :auth_priv
      _ -> nil
    end
  end

  def normalize_security_level(_), do: nil

  @spec normalize_auth_protocol(atom() | String.t() | nil) :: atom() | nil
  def normalize_auth_protocol(value) do
    case value do
      atom when is_atom(atom) ->
        normalize_protocol(atom, @auth_protocols)

      binary when is_binary(binary) ->
        case String.upcase(String.trim(binary)) do
          "MD5" -> :md5
          "SHA" -> :sha
          "SHA224" -> :sha224
          "SHA-224" -> :sha224
          "SHA256" -> :sha256
          "SHA-256" -> :sha256
          "SHA384" -> :sha384
          "SHA-384" -> :sha384
          "SHA512" -> :sha512
          "SHA-512" -> :sha512
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec normalize_priv_protocol(atom() | String.t() | nil) :: atom() | nil
  def normalize_priv_protocol(value) do
    case value do
      atom when is_atom(atom) ->
        normalize_protocol(atom, @priv_protocols)

      binary when is_binary(binary) ->
        case String.upcase(String.trim(binary)) do
          "DES" -> :des
          "AES" -> :aes
          "AES192" -> :aes192
          "AES-192" -> :aes192
          "AES256" -> :aes256
          "AES-256" -> :aes256
          "AES-192-C" -> :aes192c
          "AES-256-C" -> :aes256c
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp format_protocol(nil, _mapping, _opts), do: nil

  defp format_protocol(value, mapping, opts) do
    style = Keyword.get(opts, :style, :compact)
    allow_binary? = Keyword.get(opts, :allow_binary?, false)

    case normalize_protocol(value, mapping) do
      nil when allow_binary? and is_binary(value) ->
        String.upcase(value)

      nil ->
        nil

      normalized ->
        mapping
        |> Map.get(normalized, %{})
        |> Map.get(style)
    end
  end

  defp normalize_protocol(value, mapping) when is_atom(value) do
    if Map.has_key?(mapping, value), do: value, else: nil
  end

  defp normalize_protocol(value, mapping) when is_binary(value) do
    normalized = String.upcase(String.trim(value))

    Enum.find_value(mapping, fn {atom, styles} ->
      if normalized in Map.values(styles), do: atom, else: nil
    end)
  end

  defp normalize_protocol(_value, _mapping), do: nil
end
