defmodule ServiceRadar.Automation.Ansible.SafeFailureEvidence do
  @moduledoc """
  Secret-free structural classification for logs and durable failure evidence.

  Arbitrary failures may contain HTTP bodies, database parameters, Ash
  changesets, credentials, or operator input. This module retains only a
  bounded atom tag or exception module and never calls `inspect/1` on the
  supplied value. It is intentionally generic so every automation path can
  share the same fail-closed boundary.
  """

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @max_code_bytes 128
  @max_module_bytes 256

  @type classification :: %{required(String.t()) => String.t() | non_neg_integer()}

  @spec code(term()) :: String.t()
  def code(reason), do: reason |> classification() |> Map.fetch!("code")

  @spec classification(term()) :: classification()
  def classification(reason) when is_atom(reason) do
    evidence("atom", normalize_code(reason))
  end

  def classification({:error, reason}) when is_atom(reason) do
    evidence("error_atom", normalize_code(reason))
  end

  def classification(%{__struct__: module}) when is_atom(module) do
    "exception_struct"
    |> evidence("internal_error")
    |> Map.put("module", bounded_module(module))
  end

  def classification(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) ->
        "tagged_tuple"
        |> evidence(normalize_code(tag))
        |> Map.put("arity", tuple_size(reason))

      _other ->
        evidence("redacted", "internal_error")
    end
  end

  def classification(_reason), do: evidence("redacted", "internal_error")

  @spec digest(term()) :: {:ok, String.t()} | {:error, term()}
  def digest(reason), do: reason |> classification() |> CanonicalJSON.digest()

  @doc "Returns bounded Logger metadata without rendering the original failure."
  @spec log_metadata(term()) :: keyword()
  def log_metadata(reason) do
    evidence = classification(reason)

    [failure_code: evidence["code"], failure_kind: evidence["kind"]]
    |> maybe_put(:failure_arity, evidence["arity"])
    |> maybe_put(:failure_module, evidence["module"])
  end

  defp evidence(kind, code) do
    %{
      "schema" => "serviceradar.safe_failure_evidence.v1",
      "code" => code,
      "kind" => kind
    }
  end

  defp normalize_code(code) do
    normalized = code |> Atom.to_string() |> String.downcase()

    if Regex.match?(~r/\A[a-z0-9_.-]+\z/, normalized),
      do: String.slice(normalized, 0, @max_code_bytes),
      else: "internal_error"
  end

  defp bounded_module(module) do
    module
    |> Atom.to_string()
    |> String.slice(0, @max_module_bytes)
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Keyword.put(metadata, key, value)
end
