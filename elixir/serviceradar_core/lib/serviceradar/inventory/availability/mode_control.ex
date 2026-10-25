defmodule ServiceRadar.Inventory.Availability.ModeControl do
  @moduledoc """
  The deployment's availability mode control (design Decision 10, "Automatic
  progression"):

    * `auto` (the default): core moves `legacy` to `shadow` by itself and runs the
      cutover when the readiness conditions hold
      (`ServiceRadar.Inventory.Availability.Readiness`);
    * `hold_legacy`: core stays in, or rolls back to, `legacy`;
    * `hold_shadow`: core stays in, or returns to, `shadow`, and never cuts over.

  The control is stored on the settings row (`availability_settings.mode_control`) and
  edited in the settings UI. A GitOps install pins it with the Helm value
  `core.availability.modeControl`, which reaches core as
  `SERVICERADAR_AVAILABILITY_MODE_CONTROL` (`config :serviceradar_core, #{inspect(__MODULE__)},
  pin: ...`). A pin wins over the stored control. A pin that is not one of the three
  values is reported as invalid and holds the mode where it is, so a typo never
  starts a cutover. `ServiceRadar.Inventory.Availability.ProgressionWorker` applies the
  control.
  """

  alias ServiceRadar.Inventory.Availability.ProgressionWorker
  alias ServiceRadar.Inventory.Availability.Setting

  require Ash.Query

  @type t :: :auto | :hold_legacy | :hold_shadow
  @type pin :: nil | {:ok, t()} | {:invalid, String.t()}

  @controls %{"auto" => :auto, "hold_legacy" => :hold_legacy, "hold_shadow" => :hold_shadow}

  @doc "The control values, as stored."
  @spec values() :: [String.t()]
  def values, do: Map.keys(@controls)

  @doc "Parses a stored or configured control value."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(value) when is_atom(value) and not is_nil(value), do: parse(Atom.to_string(value))
  def parse(value) when is_binary(value), do: Map.fetch(@controls, String.trim(value))
  def parse(_value), do: :error

  @doc """
  The pin this node runs with: `nil` when unset or blank, `{:ok, control}`, or
  `{:invalid, raw}` for any other value.
  """
  @spec pin() :: pin()
  def pin do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:pin)
    |> parse_pin()
  end

  defp parse_pin(nil), do: nil

  defp parse_pin(raw) when is_binary(raw) do
    case {String.trim(raw), parse(raw)} do
      {"", _parsed} -> nil
      {_trimmed, {:ok, control}} -> {:ok, control}
      {trimmed, :error} -> {:invalid, trimmed}
    end
  end

  defp parse_pin(raw), do: {:invalid, inspect(raw)}

  @doc "The value recorded in `mode_control_pin` for `pin`."
  @spec pin_value(pin()) :: String.t() | nil
  def pin_value(nil), do: nil
  def pin_value({:ok, control}), do: Atom.to_string(control)
  def pin_value({:invalid, raw}), do: raw

  @doc """
  Sets the stored control as `opts[:scope]` or `opts[:actor]` and enqueues a
  progression run, so the control applies without waiting for the next minute. Refused
  (`Ash.Error.Forbidden`) while core records a pin.
  """
  @spec set(t() | String.t(), keyword()) :: {:ok, Setting.t()} | {:error, term()}
  def set(control, opts) do
    with {:ok, control} <- parse_or_error(control),
         {:ok, setting} <- read(opts),
         {:ok, updated} <-
           setting
           |> Ash.Changeset.for_update(:set_mode_control, %{mode_control: control}, opts)
           |> Ash.update(opts) do
      :ok = ProgressionWorker.enqueue()
      {:ok, updated}
    end
  end

  defp parse_or_error(control) do
    case parse(control) do
      {:ok, control} -> {:ok, control}
      :error -> {:error, {:invalid_mode_control, control}}
    end
  end

  @doc "Reads the settings row as `opts[:scope]` or `opts[:actor]`."
  @spec read(keyword()) :: {:ok, Setting.t()} | {:error, term()}
  def read(opts) do
    Setting
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %Setting{} = setting} -> {:ok, setting}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
