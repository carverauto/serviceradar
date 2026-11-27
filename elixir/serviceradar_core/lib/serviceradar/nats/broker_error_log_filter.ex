defmodule ServiceRadar.NATS.BrokerErrorLogFilter do
  @moduledoc """
  Rewrites Gnat's `gnat_error_from_broker` reports into a complete log message
  that names the connection it came from.

  Gnat reports a broker `-ERR` (for example a Permissions Violation naming the
  denied subject) with a bare `:error_logger.error_report/1` carrying only the
  message. Log exporters then render the report with an inspect limit, so the
  subject is cut off (`<<"Perm"...>>`) and nothing says which NATS identity was
  refused. This filter replaces that report with a plain string holding the
  full broker text plus the connection's name, endpoint and credential source.

  A publish denial is also recorded in `ServiceRadar.NATS.PublishDenials` against the
  connection that received it (the filter runs in that Gnat process), which is how a JetStream
  publish learns its PubAck timeout was a denial.
  """

  alias ServiceRadar.NATS.PublishDenials

  @filter_id :serviceradar_nats_broker_errors

  @doc """
  Installs the filter as a primary logger filter. Safe to call repeatedly.
  """
  @spec install(keyword()) :: :ok
  def install(identity) when is_list(identity) do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, Map.new(identity)}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc false
  def filter(%{msg: {:report, report}} = event, identity) do
    case broker_error_message(report) do
      {:ok, message} ->
        PublishDenials.note(self(), message)
        connection = identity_value(identity, :connection)
        endpoint = identity_value(identity, :endpoint)
        credentials = identity_value(identity, :credentials)

        meta =
          event
          |> Map.get(:meta, %{})
          |> Map.merge(%{
            nats_connection: connection,
            nats_endpoint: endpoint,
            nats_credentials: credentials
          })

        if session_grant_expired?(message) do
          # ManagedCertificateAuthorization issues jittered user-JWT grants (12h +/- 20%)
          # so the broker periodically expires long-lived sessions and Gnat reconnects to
          # re-authenticate. Treat that planned rotation as info rather than an error.
          text =
            "NATS session grant expired on connection #{connection} " <>
              "(#{endpoint}, credentials: #{credentials}); reconnecting to re-authenticate"

          %{event | level: :info, msg: {:string, text}, meta: meta}
        else
          text =
            "NATS broker error on connection #{connection} " <>
              "(#{endpoint}, credentials: #{credentials}): " <>
              message

          %{event | msg: {:string, text}, meta: meta}
        end

      :error ->
        :ignore
    end
  end

  def filter(_event, _identity), do: :ignore

  defp session_grant_expired?(message) when is_binary(message) do
    String.trim(message) == "User Authentication Expired"
  end

  defp session_grant_expired?(_message), do: false

  defp broker_error_message(%{label: {:error_logger, :error_report}, report: report}),
    do: broker_error_message(report)

  defp broker_error_message(report) when is_list(report) do
    if Keyword.keyword?(report) and Keyword.get(report, :type) == :gnat_error_from_broker do
      {:ok, to_text(Keyword.get(report, :message))}
    else
      :error
    end
  end

  defp broker_error_message(_report), do: :error

  defp to_text(message) when is_binary(message), do: message
  defp to_text(message), do: inspect(message, limit: :infinity, printable_limit: :infinity)

  defp identity_value(identity, key), do: identity |> Map.get(key, "unknown") |> to_string()
end
