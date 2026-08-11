defmodule ServiceRadar.Notifications.Renderers.Format do
  @moduledoc """
  The contract one payload format implements, plus the handful of helpers every
  format needs.

  A format module is deliberately tiny and pure: finished strings in, a
  provider-shaped map out. It does no substitution (that is
  `ServiceRadar.Notifications.Renderer`), no redaction (that is
  `ServiceRadar.Automation.Northbound.ActionRedaction`, applied by the renderer
  after this module returns), no I/O, and no clock reads.

  ## `escape/1`

  Escaping is a property of the destination format, not of the template engine,
  so it lives here. It is applied to **substituted values only** - never to the
  literal text an operator typed - which is what lets an `:html` template contain
  real markup while an alert title containing `<script>` still renders as text.
  The default is identity; only `Html` overrides it.

  This is also why the engine never needs `raw/1`: nothing is ever marked safe
  and then unmarked. The literal template is trusted because an operator with
  `notifications.routes.manage` wrote it; the substituted value is untrusted
  because it came from an alert.
  """

  alias ServiceRadar.Notifications.Renderers.Content

  @doc "The `payload_format` atom this module renders."
  @callback payload_format() :: atom()

  @doc "Shape finished strings into the provider's payload."
  @callback render(Content.t()) :: map()

  @doc "Escape one substituted value for this destination format."
  @callback escape(String.t()) :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour ServiceRadar.Notifications.Renderers.Format

      import ServiceRadar.Notifications.Renderers.Format,
        only: [compact: 1, presence: 1, blank?: 1, truncate: 2, join_nonempty: 2]

      alias ServiceRadar.Notifications.Renderers.Content

      @impl true
      def escape(value) when is_binary(value), do: value

      defoverridable escape: 1
    end
  end

  @doc """
  Drops keys whose value is `nil` or an empty list.

  Providers reject payloads with explicit nulls more often than they tolerate
  them (Discord rejects a null `title`, PagerDuty rejects a null `timestamp`), so
  an absent value is expressed by an absent key.
  """
  @spec compact(map()) :: map()
  def compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value == nil or value == [] end)
    |> Map.new()
  end

  @doc "The value, or `nil` when it is nil or blank after trimming."
  @spec presence(term()) :: String.t() | nil
  def presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def presence(_value), do: nil

  @doc "True when the value is nil or a blank string."
  @spec blank?(term()) :: boolean()
  def blank?(value), do: presence(value) == nil

  @doc """
  Hard-truncates to `limit` characters, marking the cut with an ellipsis when
  there is room for one.

  Every destination has a hard field limit - a Slack header is 150 characters, a
  Discord embed title 256, a PagerDuty summary 1024 - and exceeding it is a 400,
  which is a permanent failure. Truncating here means a long alert title degrades
  the notification instead of losing it.
  """
  @spec truncate(term(), pos_integer()) :: String.t() | nil
  def truncate(nil, _limit), do: nil

  def truncate(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if String.length(value) <= limit do
      value
    else
      cut(value, limit)
    end
  end

  def truncate(value, limit), do: truncate(to_string(value), limit)

  defp cut(value, limit) when limit > 3, do: String.slice(value, 0, limit - 3) <> "..."
  defp cut(value, limit), do: String.slice(value, 0, limit)

  @doc "Joins the non-blank parts with `separator`."
  @spec join_nonempty([term()], String.t()) :: String.t()
  def join_nonempty(parts, separator) when is_list(parts) and is_binary(separator) do
    parts
    |> Enum.map(&presence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(separator)
  end
end
