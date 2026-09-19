defmodule ServiceRadar.Otel.LogSelfFilter do
  @moduledoc """
  Handler-scoped `:logger` filter that drops records produced by the OTLP log
  exporter/handler themselves.

  Those modules used to `LOG_WARNING` on export failure. This handler's level
  is `:warning`, so those records re-entered the same gen_statem mailbox and
  rebuilt the batch that failed to export — a feedback loop that filled the
  handler until the cgroup OOM-killed core-elx.
  """

  @self_modules MapSet.new([
                  :otel_exporter_logs_otlp,
                  :serviceradar_otel_log_handler,
                  :serviceradar_otel_log_handler_v2
                ])

  @doc """
  `:logger` filter callback. Returns `:stop` for exporter/handler MFA, `:ignore`
  otherwise so later filters still run.
  """
  @spec filter(:logger.log_event(), term()) :: :stop | :ignore
  def filter(%{meta: %{mfa: {mod, _, _}}}, _arg) do
    if MapSet.member?(@self_modules, mod), do: :stop, else: :ignore
  end

  def filter(_log_event, _arg), do: :ignore
end
