defmodule ServiceRadarWebNG.Edge.ComponentTemplates do
  @moduledoc """
  Functions for listing component templates from the datasvc KV store.

  Templates are stored in NATS JetStream KV with keys following the pattern:
  `templates/{component_type}/{security_mode}/{kind}.json`

  ## Example

      # List all checker templates with mTLS security
      {:ok, templates} = ComponentTemplates.list("checker", "mtls")

      # Returns:
      [
        %{
          component_type: "checker",
          kind: "sysmon",
          security_mode: "mtls",
          template_key: "templates/checkers/mtls/sysmon.json"
        }
      ]

  """

  require Logger

  alias ServiceRadarWebNG.Datasvc.KV

  @type template :: %{
          component_type: String.t(),
          kind: String.t(),
          security_mode: String.t(),
          template_key: String.t()
        }

  @doc """
  Lists all templates for a given component type and security mode.

  Returns `{:ok, [template]}` on success, `{:error, reason}` on failure.
  If datasvc is not configured or unavailable, returns an empty list.

  ## Parameters

    - `component_type` - The component type (e.g., "checker", "poller")
    - `security_mode` - The security mode (e.g., "mtls", "insecure")
    - `opts` - Optional keyword list:
      - `:timeout` - gRPC timeout in milliseconds (default: 5000)

  ## Examples

      iex> ComponentTemplates.list("checker", "mtls")
      {:ok, [%{component_type: "checker", kind: "sysmon", ...}]}

      iex> ComponentTemplates.list("poller", "insecure")
      {:ok, []}

  """
  @spec list(String.t(), String.t(), keyword()) :: {:ok, [template()]} | {:error, term()}
  def list(component_type, security_mode, opts \\ []) do
    prefix = build_prefix(component_type, security_mode)

    case KV.list_keys(prefix, opts) do
      {:ok, keys} ->
        templates =
          keys
          |> Enum.map(&parse_template_key(&1, component_type, security_mode))
          |> Enum.reject(&is_nil/1)

        {:ok, templates}

      {:error, :not_configured} ->
        Logger.debug("Datasvc not configured, returning empty templates list")
        {:ok, []}

      {:error, {:connection_failed, _reason}} ->
        Logger.warning("Datasvc connection failed, returning empty templates list")
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the content of a specific template by key.

  Returns `{:ok, content}` on success, `{:ok, nil}` if not found,
  or `{:error, reason}` on failure.
  """
  @spec get(String.t(), keyword()) :: {:ok, binary() | nil} | {:error, term()}
  def get(template_key, opts \\ []) do
    case KV.get(template_key, opts) do
      {:ok, value, _revision} when not is_nil(value) ->
        {:ok, value}

      {:ok, nil, _revision} ->
        {:ok, nil}

      {:error, :not_configured} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all available component types that have templates.

  This is a convenience function that queries known component types.
  """
  @spec available_component_types() :: [String.t()]
  def available_component_types do
    ["checker", "poller"]
  end

  @doc """
  Lists all available security modes.
  """
  @spec available_security_modes() :: [String.t()]
  def available_security_modes do
    ["mtls", "insecure"]
  end

  @doc """
  Checks if the datasvc KV store is available.
  """
  @spec available?() :: boolean()
  def available? do
    KV.available?()
  end

  # Private functions

  # Build the prefix for listing template keys
  # Pattern: templates/{component_type}s/{security_mode}/
  # Note: component_type is pluralized (checker -> checkers)
  defp build_prefix(component_type, security_mode) do
    plural_type = pluralize(component_type)
    "templates/#{plural_type}/#{security_mode}/"
  end

  # Simple pluralization for component types
  defp pluralize("checker"), do: "checkers"
  defp pluralize("poller"), do: "pollers"
  defp pluralize(type), do: type <> "s"

  # Parse a template key into a template map
  # Key format: templates/checkers/mtls/sysmon.json
  defp parse_template_key(key, component_type, security_mode) do
    prefix = build_prefix(component_type, security_mode)

    case String.replace_prefix(key, prefix, "") do
      ^key ->
        # Prefix not found, invalid key
        nil

      remainder ->
        if String.ends_with?(remainder, ".json") do
          kind = Path.basename(remainder, ".json")

          %{
            component_type: component_type,
            kind: kind,
            security_mode: security_mode,
            template_key: key
          }
        else
          # Not a .json file
          nil
        end
    end
  end
end
