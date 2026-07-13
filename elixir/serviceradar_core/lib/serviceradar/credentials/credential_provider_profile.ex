defmodule ServiceRadar.Credentials.CredentialProviderProfile do
  @moduledoc """
  Behaviour + registry describing how a network-credential provider materializes
  into policy-derived plugin assignments.

  The materializer (`ServiceRadar.Credentials.PluginAssignmentMaterializer`) is
  parameterized over a profile so that `proxmox`, `unifi-protect`, and `axis`
  rules all flow through the same SRQL targeting path. Each profile supplies the
  provider-specific constants (provider string, purpose set, plugin ids), the
  broker grant spec, and the stored params template.

  `host_source/0` documents whether a provider resolves hosts per target from
  SRQL `items[]` or from validated static endpoint metadata. Static endpoints
  remain public assignment data; credentials are always brokered separately.
  """

  alias ServiceRadar.Credentials.ProviderProfiles.AxisProfile
  alias ServiceRadar.Credentials.ProviderProfiles.HpnaProfile
  alias ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile
  alias ServiceRadar.Credentials.ProviderProfiles.UnifiProtectProfile

  @typedoc "Purpose the worker fans a rule out over, e.g. :camera_inventory."
  @type purpose :: atom()

  @typedoc "Context passed to params_template/4 with the issued grant + resolved public fields."
  @type template_ctx :: %{
          required(:grant) => map(),
          required(:secret_ref) => String.t(),
          optional(:username) => String.t() | nil
        }

  @doc "Stable provider string matched against `NetworkCredentialRule.provider`."
  @callback provider() :: String.t()

  @doc "Ordered purposes the periodic worker reconciles for this provider."
  @callback purposes() :: [purpose()]

  @doc "Logical plugin id (`plugin_id`) the assignment targets for a purpose."
  @callback plugin_id(purpose()) :: String.t()

  @doc """
  Whether a rule is eligible for a purpose.

  Proxmox overrides this to keep the historical coupling where an
  `inventory_enrichment` API-token rule is also console-eligible.
  """
  @callback rule_has_purpose?(rule :: map(), purpose()) :: boolean()

  @doc """
  Build the credential-broker grant attrs + `to_payload` extras for a purpose.

  Returns `{grant_attrs, extras}`. The materializer issues the grant and injects
  the resulting payload into `params_template/4` via the context `:grant` key.
  """
  @callback grant_spec(purpose(), rule :: map(), secret_id :: String.t(), agent_id :: String.t()) ::
              {map(), map()}

  @doc """
  Build the stored params template embedding the issued grant payload.

  `ctx` carries the issued `:grant` payload, the `:secret_ref`, and (when
  `resolve_username?/2` is true) the resolved public `:username`.
  """
  @callback params_template(purpose(), rule :: map(), secret_id :: String.t(), template_ctx()) ::
              {:ok, map()} | {:error, term()}

  @doc "Whether the materializer should load the secret to bake the public username plaintext."
  @callback resolve_username?(purpose(), rule :: map()) :: boolean()

  @doc "Secret-ref field names the config-gen allowlist must resolve for this provider."
  @callback secret_ref_fields() :: [String.t()]

  @doc "Where provider endpoints originate."
  @callback host_source() :: :per_target_items | :static_endpoint_metadata

  @proxmox_profiles [ProxmoxProfile]
  @camera_profiles [UnifiProtectProfile, AxisProfile]
  @inventory_profiles [HpnaProfile]
  @all_profiles @proxmox_profiles ++ @camera_profiles ++ @inventory_profiles

  @doc "All registered provider profiles."
  @spec all_profiles() :: [module()]
  def all_profiles, do: @all_profiles

  @doc "Camera provider profiles (unifi-protect + axis)."
  @spec camera_profiles() :: [module()]
  def camera_profiles, do: @camera_profiles

  @doc "External inventory provider profiles materialized through producer schedules."
  @spec inventory_profiles() :: [module()]
  def inventory_profiles, do: @inventory_profiles

  @doc "Resolve a profile module by its provider string, if registered."
  @spec profile_for(String.t()) :: {:ok, module()} | :error
  def profile_for(provider) when is_binary(provider) do
    case Enum.find(@all_profiles, &(&1.provider() == provider)) do
      nil -> :error
      profile -> {:ok, profile}
    end
  end

  def profile_for(_provider), do: :error

  @doc """
  Reverse lookup: logical plugin id → `{profile, purpose}`.

  Lets assignment-time validation derive the credential provider/purpose a
  plugin's materialized inputs come from, without hardcoding per-plugin
  knowledge in the UI.
  """
  @spec profile_purpose_for_plugin_id(String.t()) :: {:ok, {module(), purpose()}} | :error
  def profile_purpose_for_plugin_id(plugin_id) when is_binary(plugin_id) do
    Enum.find_value(@all_profiles, :error, fn profile ->
      Enum.find_value(profile.purposes(), fn purpose ->
        if profile.plugin_id(purpose) == plugin_id, do: {:ok, {profile, purpose}}
      end)
    end)
  end

  def profile_purpose_for_plugin_id(_plugin_id), do: :error
end
