defmodule ServiceRadar.SNMPProfiles.CredentialDsl do
  @moduledoc false

  @doc """
  The inline credential inputs of an action that runs
  `ServiceRadar.SNMPProfiles.Changes.EncryptCredentials`, which documents what
  each one means.

  A blank (empty or whitespace-only) `community`/`auth_password`/`priv_password`
  keeps the stored value; `clear_credentials` is the only way to remove one. Any
  other value is stored exactly as given: whitespace at either end is part of
  the secret, so `trim?: false` overrides the `:string` default.
  """
  defmacro credential_action_arguments do
    quote do
      argument :community, :string,
        allow_nil?: true,
        sensitive?: true,
        constraints: [trim?: false]

      argument :auth_password, :string,
        allow_nil?: true,
        sensitive?: true,
        constraints: [trim?: false]

      argument :priv_password, :string,
        allow_nil?: true,
        sensitive?: true,
        constraints: [trim?: false]

      argument :clear_credentials, {:array, :atom} do
        allow_nil? false
        default []

        constraints items: [
                      one_of:
                        ServiceRadar.SNMPProfiles.Changes.EncryptCredentials.clearable_fields()
                    ]

        description "Stored inline credentials to remove: community, auth_password, priv_password"
      end
    end
  end

  defmacro credential_attributes do
    quote do
      attribute :version, :atom do
        allow_nil? false
        default :v2c
        public? true
        constraints one_of: [:v1, :v2c, :v3]
        description "SNMP protocol version"
      end

      attribute :community_encrypted, :binary do
        allow_nil? true
        public? false
        description "Encrypted community string for SNMPv1/v2c"
      end

      attribute :username, :string do
        allow_nil? true
        public? true
        # A USM user name may contain spaces, including at either end.
        constraints trim?: false
        description "Username for SNMPv3"
      end

      attribute :security_level, :atom do
        allow_nil? true
        public? true
        constraints one_of: [:no_auth_no_priv, :auth_no_priv, :auth_priv]
        description "SNMPv3 security level"
      end

      attribute :auth_protocol, :atom do
        allow_nil? true
        public? true
        constraints one_of: [:md5, :sha, :sha224, :sha256, :sha384, :sha512]
        description "SNMPv3 authentication protocol"
      end

      attribute :auth_password_encrypted, :binary do
        allow_nil? true
        public? false
        description "Encrypted SNMPv3 auth password"
      end

      attribute :priv_protocol, :atom do
        allow_nil? true
        public? true
        constraints one_of: [:des, :aes, :aes192, :aes256, :aes192c, :aes256c]
        description "SNMPv3 privacy (encryption) protocol"
      end

      attribute :priv_password_encrypted, :binary do
        allow_nil? true
        public? false
        description "Encrypted SNMPv3 privacy password"
      end

      attribute :credential_secret_id, :uuid do
        allow_nil? true
        public? true
        description "Optional NetworkCredentialSecret used by the credential broker"
      end
    end
  end
end
