defmodule ServiceRadar.Observability.PluginResultHandler do
  @moduledoc """
  Behaviour implemented by registered platform plugin-result handlers so
  `ServiceRadar.Observability.PluginResultIngestor` and durable edge projectors
  classify outcomes into `applied`, `settled`, `refused`, and `retryable`.
  """

  alias ServiceRadar.Observability.PluginResultHandlerOutcome

  @callback supports?(payload :: map(), status :: map()) :: boolean()
  @callback ingest(payload :: map(), status :: map(), opts :: keyword()) ::
              PluginResultHandlerOutcome.t()
  @callback settled_reasons() :: [PluginResultHandlerOutcome.reason_atom()]
  @callback refused_reasons() :: [PluginResultHandlerOutcome.reason_atom()]
end

defmodule ServiceRadar.Observability.PluginResultHandlerOutcome do
  @moduledoc """
  Four-way outcome contract (`applied`, `settled`, `refused`, `retryable`),
  normalization, unclassified-error telemetry, and multi-handler precedence
  combination for `ServiceRadar.Observability.PluginResultIngestor`.
  """

  require Logger

  @type reason_atom :: atom()
  @type metadata :: map()

  @type t ::
          :ok
          | {:settled, reason_atom()}
          | {:settled, reason_atom(), metadata()}
          | {:refused, reason_atom()}
          | {:refused, reason_atom(), metadata()}
          | {:error, term()}

  @type classified :: %{
          outcome: :applied | :settled | :refused | :retryable,
          handler: String.t(),
          handler_module: module(),
          reason: atom(),
          metadata: map(),
          raw_error: term()
        }

  @ash_and_ecto_structs [
    Ash.Changeset,
    Ash.Query,
    Ash.ActionInput,
    Ash.BulkResult,
    Ecto.Changeset
  ]

  @known_retryable_atoms [
    :running_config_ingest_failed,
    :running_config_artifact_cleanup_failed,
    :bulk_update_failed,
    :same_observation_authority_changed,
    :source_observation_preflight_failed,
    :source_observation_ingest_failed,
    :plugin_assignment_package_not_loaded,
    :incomplete_hosted_inventory_read,
    :rollback,
    :timeout,
    :closed,
    :econnrefused,
    :unavailable,
    :advisory_lock_busy,
    :lookup_failed
  ]

  @known_retryable_tags [
    :retryable,
    :running_config_artifact_fetch_failed,
    :running_config_ingest_failed,
    :interface_check_record_failed,
    :plugin_assignment_lookup_failed,
    :credential_rule_lookup_failed,
    :device_lookup_failed,
    :identifier_lookup_failed,
    :source_lookup_failed,
    :camera_device_not_found,
    :cursor_gap,
    :unexpected_source_upsert_result,
    :unexpected_batch_upsert_result,
    :unexpected_bulk_upsert_result,
    :advisory_locks_busy,
    :sync_ingest_failed,
    :awx_fence_failed,
    :awx_membership_persist_failed,
    :threat_intel_persist_failed,
    :camera_event_publish_failed,
    :camera_inventory_sync_failed,
    :vulnerability_advisory_persist_failed
  ]

  @spec short_handler_name(module()) :: String.t()
  def short_handler_name(handler) when is_atom(handler) do
    handler
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @spec classify(module(), term(), map()) :: classified()
  def classify(handler, raw_result, _context \\ %{}) when is_atom(handler) do
    short_name = short_handler_name(handler)

    case raw_result do
      :ok ->
        %{
          outcome: :applied,
          handler: short_name,
          handler_module: handler,
          reason: :ok,
          metadata: %{},
          raw_error: nil
        }

      {:settled, reason} when is_atom(reason) ->
        classify(handler, {:settled, reason, %{}})

      {:settled, reason, metadata} when is_atom(reason) and is_map(metadata) ->
        if declared_reason?(handler, :settled_reasons, reason) do
          clean_metadata = sanitize_metadata(metadata)

          %{
            outcome: :settled,
            handler: short_name,
            handler_module: handler,
            reason: reason,
            metadata: clean_metadata,
            raw_error: nil
          }
        else
          emit_unclassified_error(short_name, {:undeclared_settled_reason, reason})

          %{
            outcome: :retryable,
            handler: short_name,
            handler_module: handler,
            reason: :retryable_error,
            metadata: %{},
            raw_error: {:undeclared_settled_reason, reason}
          }
        end

      {:refused, reason} when is_atom(reason) ->
        classify(handler, {:refused, reason, %{}})

      {:refused, reason, metadata} when is_atom(reason) and is_map(metadata) ->
        if declared_reason?(handler, :refused_reasons, reason) do
          clean_metadata = sanitize_metadata(metadata)

          %{
            outcome: :refused,
            handler: short_name,
            handler_module: handler,
            reason: reason,
            metadata: clean_metadata,
            raw_error: {reason, clean_metadata}
          }
        else
          emit_unclassified_error(short_name, {:undeclared_refused_reason, reason})

          %{
            outcome: :retryable,
            handler: short_name,
            handler_module: handler,
            reason: :retryable_error,
            metadata: %{},
            raw_error: {:undeclared_refused_reason, reason}
          }
        end

      {:error, reason} ->
        if not known_retryable_reason?(reason) do
          emit_unclassified_error(short_name, reason)
        end

        %{
          outcome: :retryable,
          handler: short_name,
          handler_module: handler,
          reason: :retryable_error,
          metadata: %{},
          raw_error: reason
        }

      other ->
        emit_unclassified_error(short_name, {:unexpected_handler_return, other})

        %{
          outcome: :retryable,
          handler: short_name,
          handler_module: handler,
          reason: :retryable_error,
          metadata: %{},
          raw_error: {:unexpected_handler_return, other}
        }
    end
  end

  @doc """
  Combines evaluated handler outcomes using the strict precedence lattice:
  `retryable > refused > applied > settled`.
  """
  @spec combine([classified()]) ::
          {:applied, [classified()]}
          | {:settled, atom(), map(), [classified()]}
          | {:refused, atom(), map(), [classified()]}
          | {:retryable, [classified()]}
  def combine([]), do: {:applied, []}

  def combine(outcomes) when is_list(outcomes) do
    cond do
      Enum.any?(outcomes, &(&1.outcome == :retryable)) ->
        {:retryable, outcomes}

      Enum.any?(outcomes, &(&1.outcome == :refused)) ->
        primary = Enum.find(outcomes, &(&1.outcome == :refused))

        refused_handlers =
          for item <- outcomes, item.outcome == :refused do
            %{handler: item.handler, reason: item.reason, metadata: item.metadata}
          end

        detail = Map.put(primary.metadata, :handlers, refused_handlers)
        {:refused, primary.reason, detail, outcomes}

      Enum.any?(outcomes, &(&1.outcome == :applied)) ->
        {:applied, outcomes}

      true ->
        primary = Enum.find(outcomes, &(&1.outcome == :settled))

        settled_handlers =
          for item <- outcomes, item.outcome == :settled do
            %{handler: item.handler, reason: item.reason, metadata: item.metadata}
          end

        detail = Map.put(primary.metadata, :handlers, settled_handlers)
        {:settled, primary.reason, detail, outcomes}
    end
  end

  @spec known_retryable_reason?(term()) :: boolean()
  def known_retryable_reason?({tag, _})
      when tag in [
             :handler_not_loadable,
             :invalid_handler,
             :support_check_failed,
             :unexpected_support_result,
             :invalid_proxmox_source_scope_resolver_return
           ],
      do: false

  def known_retryable_reason?(reason) when is_exception(reason), do: true
  def known_retryable_reason?(%struct{}) when struct in @ash_and_ecto_structs, do: true
  def known_retryable_reason?(reason) when reason in @known_retryable_atoms, do: true
  def known_retryable_reason?({kind, _}) when kind in [:exit, :throw], do: true

  def known_retryable_reason?(reason) when is_tuple(reason) and tuple_size(reason) >= 2 do
    lead = elem(reason, 0)

    lead in @known_retryable_tags or
      reason |> Tuple.to_list() |> Enum.any?(&structured_runtime_failure?/1)
  end

  def known_retryable_reason?(reason) when is_list(reason) and reason != [] do
    Enum.any?(reason, &structured_runtime_failure?/1)
  end

  def known_retryable_reason?(_reason), do: false

  defp structured_runtime_failure?(value) when is_exception(value), do: true
  defp structured_runtime_failure?(%struct{}) when struct in @ash_and_ecto_structs, do: true
  defp structured_runtime_failure?({kind, _}) when kind in [:exit, :throw], do: true

  defp structured_runtime_failure?(value) when is_list(value),
    do: Enum.any?(value, &structured_runtime_failure?/1)

  defp structured_runtime_failure?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&structured_runtime_failure?/1)

  defp structured_runtime_failure?(_value), do: false

  defp declared_reason?(handler, callback, reason) do
    Code.ensure_loaded?(handler) and
      function_exported?(handler, callback, 0) and
      reason in apply(handler, callback, [])
  end

  defp emit_unclassified_error(short_name, reason) do
    class = reason_class(reason)

    :telemetry.execute(
      [:serviceradar, :plugin_result, :handler, :unclassified_error],
      %{count: 1},
      %{handler: short_name, reason_class: class}
    )

    Logger.warning("Unclassified plugin result handler error; treating as retryable",
      handler: short_name,
      reason_class: class
    )
  end

  @spec reason_class(term()) :: String.t()
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_class(%struct{}), do: struct |> Module.split() |> List.last()

  def reason_class(reason) when is_tuple(reason) and tuple_size(reason) >= 1 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      _ -> "tuple"
    end
  end

  def reason_class(_reason), do: "unclassified"

  defp sanitize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_value(value)}
      end
    end)
  end

  defp sanitize_value(nil), do: nil

  defp sanitize_value(value) when is_boolean(value) or is_number(value) or is_atom(value),
    do: value

  defp sanitize_value(value) when is_binary(value), do: value
  defp sanitize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_value(value) when is_map(value), do: sanitize_metadata(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value), do: inspect(value, limit: 10, printable_limit: 256)

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    normalized in [
      "api_key",
      "apikey",
      "api_token",
      "access_token",
      "access_key",
      "authorization",
      "bearer",
      "bearer_token",
      "client_secret",
      "credential",
      "credentials",
      "password",
      "private_key",
      "privatekey",
      "refresh_token",
      "secret",
      "token"
    ] or String.ends_with?(normalized, ["_password", "_secret", "_token", "_access_key"])
  end

  defp sensitive_key?(_key), do: false
end
