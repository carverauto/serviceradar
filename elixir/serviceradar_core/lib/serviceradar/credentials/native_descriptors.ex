defmodule ServiceRadar.Credentials.NativeDescriptors do
  @moduledoc """
  Credential descriptors for protocols ServiceRadar speaks itself.

  A package-owned integration publishes its credential descriptor in a signed
  manifest, and `CredentialSecretBuilder` renders and stores from that. SNMP has
  no package to publish one: it is a protocol the platform implements directly,
  so the descriptor has to come from somewhere else.

  It comes from here, in **exactly the shape a manifest would supply**. That is
  the point. `CredentialSecretBuilder.build/4` is unchanged and cannot tell the
  difference, so a native credential is validated, encoded, fingerprinted and
  redacted by the same code as a package one — no second path to keep in step.

  `design.md` anticipates built-in protocol services eventually publishing
  through the same persisted descriptor contract. When that arrives this module
  is what gets published; until then it is the same data, held in code. What it
  must never become is a *registry* that package-owned providers can be resolved
  through — the change this belongs to is explicit that Wasm providers have no
  native fallback. Everything here is a protocol or core-owned feed with no
  package, and the list is meant to stay short.

  ## Why SNMP is one descriptor with two auth methods

  v1/v2c authenticate with a community string; v3 with a user, an auth secret,
  and optionally a privacy secret. Those are two ways to authenticate to the
  same protocol, which is what an auth method *is* — not two different kinds of
  credential. An operator picks the one their devices speak, exactly as they
  would choose between token and username/password for an HTTP integration.

  Both encode to `credential_kind: :snmp`, whose JSON payload is read by
  `SNMPProfiles.CredentialResolver.broker_json_credential/3`. The field ids
  below are that function's keys; renaming one here silently stops the value
  reaching the poller, so they are asserted in the tests.
  """

  @snmp_provider "snmp"
  @vulncheck_provider "vulncheck"

  @doc "Every native descriptor, keyed by provider."
  @spec all() :: %{String.t() => map()}
  def all, do: %{@snmp_provider => snmp(), @vulncheck_provider => vulncheck()}

  @doc "Fetch a native descriptor by provider, if one exists."
  @spec fetch(String.t() | nil) :: {:ok, map()} | :error
  def fetch(provider) when is_binary(provider), do: Map.fetch(all(), provider)
  def fetch(_provider), do: :error

  @doc "True when a provider is served natively rather than by a package."
  @spec native?(String.t() | nil) :: boolean()
  def native?(provider), do: match?({:ok, _descriptor}, fetch(provider))

  @doc """
  The SNMP credential descriptor.

  `plugin_id`/`plugin_version` are recorded in secret metadata by the builder.
  They read `snmp`/`native` so an operator inspecting a credential can see it
  came from the platform rather than from an installed package.
  """
  @spec snmp() :: map()
  def snmp do
    %{
      "provider" => @snmp_provider,
      "label" => "SNMP",
      "description" =>
        "Community string or SNMPv3 user credentials, reusable across SNMP profiles and targets.",
      "plugin_id" => "snmp",
      "plugin_version" => "native",
      "supports_rules" => true,
      "purposes" => ["snmp_monitoring"],
      "scope_types" => ["agent"],
      "auth_methods" => [
        %{
          "id" => "community",
          "label" => "Community string (v1 / v2c)",
          "credential_kind" => "snmp",
          "fields" => [
            %{
              "id" => "community",
              "label" => "Community string",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            }
          ]
        },
        %{
          "id" => "v3",
          "label" => "SNMPv3 user",
          "credential_kind" => "snmp",
          "fields" => [
            # Public so it is stored as the secret's `username` and can be shown
            # in a credential list without decrypting anything.
            %{
              "id" => "username",
              "label" => "Username",
              "control" => "text",
              "required" => true,
              "secret" => false,
              "public" => true
            },
            # UniFi's SNMP UI is one password with hidden SHA + AES-128 authPriv.
            # Put the same password in auth and privacy and set these explicitly.
            %{
              "id" => "security_level",
              "label" => "Security level",
              "control" => "text",
              "required" => false,
              "secret" => false,
              "public" => false
            },
            # Carried with the credential rather than left on the profile: the
            # protocols are part of what these secrets mean, so a credential
            # reused across profiles stays self-describing. The resolver reads
            # the payload first and falls back to the record, so a profile that
            # sets them still works.
            %{
              "id" => "auth_protocol",
              "label" => "Authentication protocol",
              "control" => "text",
              "required" => false,
              "secret" => false,
              "public" => false
            },
            %{
              "id" => "auth_password",
              "label" => "Authentication password",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            },
            %{
              "id" => "priv_protocol",
              "label" => "Privacy protocol",
              "control" => "text",
              "required" => false,
              "secret" => false,
              "public" => false
            },
            %{
              "id" => "priv_password",
              "label" => "Privacy password",
              "control" => "password",
              "required" => false,
              "secret" => true,
              "public" => false
            }
          ]
        }
      ],
      "provisioning" => %{"mode" => "credential_only"}
    }
  end

  @doc """
  The VulnCheck API-token descriptor used by core advisory feed ingestion.

  There is no VulnCheck plugin package. Core downloads KEV and nist-nvd2 itself,
  so the credential lives in the same operator store as package-owned secrets
  (`/settings/networks/credentials`) rather than on a second form.
  """
  @spec vulncheck() :: map()
  def vulncheck do
    %{
      "provider" => @vulncheck_provider,
      "label" => "VulnCheck",
      "description" =>
        "API token used by core to download VulnCheck KEV and nist-nvd2 advisory feeds.",
      "plugin_id" => "vulncheck",
      "plugin_version" => "native",
      "supports_rules" => false,
      "purposes" => ["vulnerability_feed_download"],
      "scope_types" => [],
      "auth_methods" => [
        %{
          "id" => "api_token",
          "label" => "API token",
          "credential_kind" => "api_token",
          "fields" => [
            %{
              "id" => "api_token",
              "label" => "API token",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            }
          ],
          "payload" => %{"format" => "scalar", "field" => "api_token"}
        }
      ],
      "provisioning" => %{"mode" => "credential_only"}
    }
  end
end
