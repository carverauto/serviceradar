defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntime do
  @moduledoc """
  Per-view NetFlow loading gates for Observability.

  Inactive tabs and overview-only views must not issue SRQL. Errors from an
  active loader stay errors; they are not coerced into empty success.
  """

  @activity_views ["explorer", "all"]

  @spec active_tab?(term()) :: boolean()
  def active_tab?("netflows"), do: true
  def active_tab?(_tab), do: false

  @spec should_load_activity?(term(), term()) :: boolean()
  def should_load_activity?(tab, view), do: active_tab?(tab) and view in @activity_views

  @spec load_summary(term(), (-> result)) :: {:ok, term()} | {:error, term()} | {:skipped, :inactive_panel}
        when result: term() | {:ok, term()} | {:error, term()}
  def load_summary(tab, fun) when is_function(fun, 0) do
    if active_tab?(tab), do: invoke(fun), else: {:skipped, :inactive_panel}
  end

  @spec load_activity(term(), term(), (-> result)) ::
          {:ok, term()} | {:error, term()} | {:skipped, :inactive_panel}
        when result: term() | {:ok, term()} | {:error, term()}
  def load_activity(tab, view, fun) when is_function(fun, 0) do
    cond do
      not active_tab?(tab) -> {:skipped, :inactive_panel}
      view in @activity_views -> invoke(fun)
      true -> {:skipped, :inactive_panel}
    end
  end

  defp invoke(fun) do
    case fun.() do
      {:error, reason} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      value -> {:ok, value}
    end
  end
end
