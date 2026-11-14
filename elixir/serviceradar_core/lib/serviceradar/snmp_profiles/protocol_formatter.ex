defmodule ServiceRadar.SNMPProfiles.ProtocolFormatter do
  @moduledoc """
  The SNMP protocol vocabulary: versions, SNMPv3 security levels and the
  authentication and privacy protocols.

  This is the one place the accepted names are written down. Three things read
  it, and they have to agree:

    * forms offer `security_level_options/0`, `auth_protocol_options/0` and
      `priv_protocol_options/0`, so an operator picks a name instead of typing
      one; the profile, target and device forms, whose fields are resource
      attributes, offer the same protocols through
      `auth_protocol_attribute_options/0` and
      `priv_protocol_attribute_options/0`;
    * `Credentials.NativeDescriptors` puts the same options on the SNMP
      credential descriptor, which is what `CredentialSecretBuilder` validates a
      submitted credential against;
    * the resolver, the agent-config compiler and the proto mapper normalise
      stored and submitted names through `normalize_security_level/1`,
      `normalize_auth_protocol/1` and `normalize_priv_protocol/1`.

  The agent's own accepted set lives in Go. The shared fixture
  `go/pkg/agent/snmp/testdata/snmpv3_protocol_contract.json` is read by this
  module's tests and by the agent's, so an option added on one side without the
  other fails a test.

  ## Offered values and accepted spellings

  An option's `value` is the canonical spelling a credential stores. The
  normalisers accept more than that, because credentials stored before the
  form offered a fixed list were free text: `SHA-256`, `sha256`, `SHA1`,
  `AES128` and `auth_priv` all still resolve. Nothing new should be stored in
  those spellings.
  """

  @type option :: %{id: atom(), value: String.t(), label: String.t()}

  # Ordered as a form should list them. `value` is what a credential stores.
  @security_level_options [
    %{
      id: :no_auth_no_priv,
      value: "noAuthNoPriv",
      label: "noAuthNoPriv (no authentication, no encryption)"
    },
    %{
      id: :auth_no_priv,
      value: "authNoPriv",
      label: "authNoPriv (authentication, no encryption)"
    },
    %{id: :auth_priv, value: "authPriv", label: "authPriv (authentication and encryption)"}
  ]

  @auth_protocol_options [
    %{id: :md5, value: "MD5", label: "MD5 (legacy, weak)"},
    %{id: :sha, value: "SHA", label: "SHA (SHA-1; legacy, weak)"},
    %{id: :sha224, value: "SHA224", label: "SHA-224"},
    %{id: :sha256, value: "SHA256", label: "SHA-256"},
    %{id: :sha384, value: "SHA384", label: "SHA-384"},
    %{id: :sha512, value: "SHA512", label: "SHA-512"}
  ]

  @priv_protocol_options [
    %{id: :des, value: "DES", label: "DES (legacy, weak)"},
    %{id: :aes, value: "AES", label: "AES (AES-128)"},
    %{id: :aes192, value: "AES192", label: "AES-192"},
    %{id: :aes256, value: "AES256", label: "AES-256"},
    %{id: :aes192c, value: "AES-192-C", label: "AES-192-C (Cisco key extension)"},
    %{id: :aes256c, value: "AES-256-C", label: "AES-256-C (Cisco key extension)"}
  ]

  @default_option_ids %{security_level: :auth_priv, auth_protocol: :sha256, priv_protocol: :aes}

  @auth_protocols %{
    md5: %{compact: "MD5", hyphenated: "MD5"},
    sha: %{compact: "SHA", hyphenated: "SHA"},
    sha224: %{compact: "SHA224", hyphenated: "SHA-224"},
    sha256: %{compact: "SHA256", hyphenated: "SHA-256"},
    sha384: %{compact: "SHA384", hyphenated: "SHA-384"},
    sha512: %{compact: "SHA512", hyphenated: "SHA-512"}
  }

  # Every protocol has its own spelling in both styles. The Cisco key-extension
  # variants are separate protocols, not spellings of AES-192 and AES-256: they
  # derive the privacy key differently, so sending one as the other gives the
  # device a key it cannot decrypt with.
  @priv_protocols %{
    des: %{compact: "DES", hyphenated: "DES"},
    aes: %{compact: "AES", hyphenated: "AES"},
    aes192: %{compact: "AES192", hyphenated: "AES-192"},
    aes256: %{compact: "AES256", hyphenated: "AES-256"},
    aes192c: %{compact: "AES192C", hyphenated: "AES-192-C"},
    aes256c: %{compact: "AES256C", hyphenated: "AES-256-C"}
  }

  @security_levels %{
    no_auth_no_priv: "noAuthNoPriv",
    auth_no_priv: "authNoPriv",
    auth_priv: "authPriv"
  }

  # Keyed by the name upcased with hyphens removed, so `SHA-256`, `sha256` and
  # `Sha256` are one entry. The agent folds names the same way.
  @auth_protocol_aliases %{
    "MD5" => :md5,
    "SHA" => :sha,
    "SHA1" => :sha,
    "SHA224" => :sha224,
    "SHA256" => :sha256,
    "SHA384" => :sha384,
    "SHA512" => :sha512
  }

  @priv_protocol_aliases %{
    "DES" => :des,
    "AES" => :aes,
    "AES128" => :aes,
    "AES192" => :aes192,
    "AES256" => :aes256,
    "AES192C" => :aes192c,
    "AES256C" => :aes256c
  }

  @security_level_aliases %{
    "noAuthNoPriv" => :no_auth_no_priv,
    "authNoPriv" => :auth_no_priv,
    "authPriv" => :auth_priv,
    "no_auth_no_priv" => :no_auth_no_priv,
    "auth_no_priv" => :auth_no_priv,
    "auth_priv" => :auth_priv
  }

  @doc "SNMPv3 security levels, in the order a form lists them."
  @spec security_level_options() :: [option()]
  def security_level_options, do: @security_level_options

  @doc "SNMPv3 authentication protocols, in the order a form lists them."
  @spec auth_protocol_options() :: [option()]
  def auth_protocol_options, do: @auth_protocol_options

  @doc "SNMPv3 privacy protocols, in the order a form lists them."
  @spec priv_protocol_options() :: [option()]
  def priv_protocol_options, do: @priv_protocol_options

  @doc """
  Authentication protocols as `{label, name}` pairs for a form whose field is
  the `auth_protocol` attribute of a profile, target or device credential
  (`sha256`) rather than a stored credential value (`SHA256`).
  """
  @spec auth_protocol_attribute_options() :: [{String.t(), String.t()}]
  def auth_protocol_attribute_options, do: attribute_options(@auth_protocol_options)

  @doc """
  Privacy protocols as `{label, name}` pairs for a form whose field is the
  `priv_protocol` attribute of a profile, target or device credential.
  """
  @spec priv_protocol_attribute_options() :: [{String.t(), String.t()}]
  def priv_protocol_attribute_options, do: attribute_options(@priv_protocol_options)

  defp attribute_options(options), do: Enum.map(options, &{&1.label, Atom.to_string(&1.id)})

  @doc """
  The option a new credential starts on for `:security_level`, `:auth_protocol`
  or `:priv_protocol`.
  """
  @spec default_option(:security_level | :auth_protocol | :priv_protocol) :: option()
  def default_option(:security_level),
    do: default_option(@security_level_options, :security_level)

  def default_option(:auth_protocol), do: default_option(@auth_protocol_options, :auth_protocol)
  def default_option(:priv_protocol), do: default_option(@priv_protocol_options, :priv_protocol)

  defp default_option(options, kind) do
    id = Map.fetch!(@default_option_ids, kind)
    Enum.find(options, &(&1.id == id))
  end

  @doc """
  The stored spelling for any accepted spelling of a security level, or `nil`
  when the name is not a security level.
  """
  @spec security_level_value(atom() | String.t() | nil) :: String.t() | nil
  def security_level_value(value),
    do: option_value(@security_level_options, normalize_security_level(value))

  @doc "The stored spelling for any accepted spelling of an authentication protocol."
  @spec auth_protocol_value(atom() | String.t() | nil) :: String.t() | nil
  def auth_protocol_value(value),
    do: option_value(@auth_protocol_options, normalize_auth_protocol(value))

  @doc "The stored spelling for any accepted spelling of a privacy protocol."
  @spec priv_protocol_value(atom() | String.t() | nil) :: String.t() | nil
  def priv_protocol_value(value),
    do: option_value(@priv_protocol_options, normalize_priv_protocol(value))

  defp option_value(_options, nil), do: nil

  defp option_value(options, id) do
    Enum.find_value(options, fn option -> if option.id == id, do: option.value end)
  end

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

  @doc """
  The wire spelling for a known security level, or `nil` when the value is
  missing or not a security level. Callers must refuse `nil` on paths that
  require a level: defaulting an unknown level to `noAuthNoPriv` would
  silently downgrade an authenticated poll to an unauthenticated one.
  """
  @spec security_level(atom() | String.t() | nil) :: String.t() | nil
  def security_level(value) do
    case normalize_security_level(value) do
      nil -> nil
      level -> Map.get(@security_levels, level)
    end
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

  def normalize_security_level(value) when is_binary(value),
    do: Map.get(@security_level_aliases, String.trim(value))

  def normalize_security_level(_), do: nil

  @spec normalize_auth_protocol(atom() | String.t() | nil) :: atom() | nil
  def normalize_auth_protocol(value),
    do: normalize_protocol_alias(value, @auth_protocols, @auth_protocol_aliases)

  @spec normalize_priv_protocol(atom() | String.t() | nil) :: atom() | nil
  def normalize_priv_protocol(value),
    do: normalize_protocol_alias(value, @priv_protocols, @priv_protocol_aliases)

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
    if Map.has_key?(mapping, value), do: value
  end

  defp normalize_protocol(value, mapping) when is_binary(value) do
    normalized = String.upcase(String.trim(value))

    Enum.find_value(mapping, fn {atom, styles} ->
      if normalized in Map.values(styles), do: atom
    end)
  end

  defp normalize_protocol(_value, _mapping), do: nil

  defp normalize_protocol_alias(value, mapping, _aliases) when is_atom(value),
    do: normalize_protocol(value, mapping)

  defp normalize_protocol_alias(value, _mapping, aliases) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> String.replace("-", "")
    |> then(&Map.get(aliases, &1))
  end

  defp normalize_protocol_alias(_value, _mapping, _aliases), do: nil
end
