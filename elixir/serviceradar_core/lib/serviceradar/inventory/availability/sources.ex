defmodule ServiceRadar.Inventory.Availability.Sources do
  @moduledoc """
  Source registrations for availability evidence (design Decision 2).

  A registration is `{source_kind, authority_class, default_ttl, min_ttl, max_ttl}`
  (TTLs in seconds). Evidence takes its class from here, never from the submitter: a
  submitter names its source kind and may only lower the class for its own instance.

    * Built-in sources register below; the ingestor that owns each one submits under
      that kind.
    * A wasm plugin registers as `plugin:<plugin_id>`, with the class its approved
      manifest declares in `availability_authority`, or `inventory_declared` when it
      declares none.

  Any other source is unregistered and its `is_available` is not evidence. The Go
  `DeviceUpdate.IsAvailable` is a plain boolean, so a sync payload cannot say "no
  opinion"; a value counts only where a registration says the field is meaningful.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Availability.AuthorityClass
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  @enforce_keys [:kind, :authority_class, :default_ttl, :min_ttl, :max_ttl]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: String.t(),
          authority_class: AuthorityClass.t(),
          default_ttl: pos_integer(),
          min_ttl: pos_integer(),
          max_ttl: pos_integer()
        }

  @hour 3_600
  # 3 x a sync interval when the source cannot say (design Decision 4).
  @sync_default_ttl 3 * @hour

  # Agent heartbeats default to 30 s (AgentConfigGenerator); self_report expires after
  # three of them.
  @builtins %{
    "agent_liveness" => {:self_report, 90, 60, @hour},
    "wifi_map" => {:managing_controller, @sync_default_ttl, 300, 24 * @hour},
    "hypervisor" => {:managing_controller, @sync_default_ttl, 300, 24 * @hour},
    "camera" => {:managing_controller, @sync_default_ttl, 300, 24 * @hour},
    "mapper" => {:passive_observation, 24 * @hour, @hour, 48 * @hour},
    "composite_check" => {:operator_policy, 600, 120, 48 * @hour}
  }

  @plugin_prefix "plugin:"

  @doc "The registration for `kind`, or `:error` for a kind nothing registers."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(@plugin_prefix <> plugin_id = kind) when plugin_id != "" do
    {:ok,
     %__MODULE__{
       kind: kind,
       authority_class: plugin_authority(plugin_id),
       default_ttl: @sync_default_ttl,
       min_ttl: 300,
       max_ttl: 24 * @hour
     }}
  end

  def fetch(kind) when is_map_key(@builtins, kind) do
    {class, default_ttl, min_ttl, max_ttl} = Map.fetch!(@builtins, kind)

    {:ok,
     %__MODULE__{
       kind: kind,
       authority_class: class,
       default_ttl: default_ttl,
       min_ttl: min_ttl,
       max_ttl: max_ttl
     }}
  end

  def fetch(_kind), do: :error

  @doc "The source kind a plugin's evidence is registered under."
  @spec plugin_kind(String.t()) :: String.t()
  def plugin_kind(plugin_id), do: @plugin_prefix <> plugin_id

  @doc """
  The class a plugin's approved manifest declares, or `inventory_declared` when it
  declares none, declares an unknown class, or has no approved package.
  """
  @spec plugin_authority(String.t()) :: AuthorityClass.t()
  def plugin_authority(plugin_id) do
    PluginPackage
    |> where([p], p.plugin_id == ^plugin_id and p.status == ^:approved)
    |> order_by([p], desc_nulls_last: p.approved_at, desc: p.inserted_at)
    |> limit(1)
    |> select([p], p.manifest)
    |> Repo.one()
    |> manifest_authority()
  end

  @doc false
  def manifest_authority(%{} = manifest) do
    raw = Map.get(manifest, "availability_authority", Map.get(manifest, :availability_authority))

    case AuthorityClass.cast(raw) do
      {:ok, class} -> class
      :error -> AuthorityClass.undeclared()
    end
  end

  def manifest_authority(_manifest), do: AuthorityClass.undeclared()
end
