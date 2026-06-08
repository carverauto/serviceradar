defmodule ServiceRadar.EventWriter.Processors.PowerDNS do
  @moduledoc """
  Processor for PowerDNS DNS Activity payloads.

  PowerDNS native add-ons emit OCSF DNS Activity records on `pdns.ocsf`.
  Storage intentionally reuses `ocsf_events`; this processor validates the
  DNS-specific class before delegating row shaping to the generic OCSF event
  processor.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.Processors.Events

  require Logger

  @impl true
  def table_name, do: Events.table_name()

  @impl true
  def process_batch(messages), do: Events.process_batch(messages)

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    case Jason.decode(data) do
      {:ok, %{"class_uid" => class_uid}} ->
        if parse_int(class_uid) == OCSF.class_dns_activity() do
          Events.parse_message(message)
        else
          Logger.debug("Skipping non-DNS OCSF event on pdns subject",
            subject: metadata[:subject],
            class_uid: class_uid
          )

          nil
        end

      {:ok, _json} ->
        Logger.debug("Skipping PowerDNS event without class_uid", subject: metadata[:subject])
        nil

      {:error, _reason} ->
        Logger.debug("Failed to parse PowerDNS OCSF message as JSON", subject: metadata[:subject])
        nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: trunc(value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_value), do: nil
end
