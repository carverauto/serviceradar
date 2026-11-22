defmodule ServiceRadar.Observability.Zen.RuleBundle do
  @moduledoc """
  The versioned Zen rule bundle published to datasvc for collectors.

  A bundle carries every rule core evaluates for one stream and subject, in
  evaluation order, each as the JDM text to compile. Its digest covers the
  schema, the stream, the subject and that ordered content, so it identifies the
  ruleset version. `rust/zen-normalize` verifies the digest before it accepts a
  bundle.

  `effective_rules/3` is the single definition of that rule list. Core's
  normalizer evaluates the same list it publishes.
  """

  import Ash.Expr

  alias ServiceRadar.Observability.ZenRule

  require Ash.Query

  @schema "serviceradar.zen.ruleset.v1"

  @type rule :: {key :: String.t(), jdm_json :: String.t()}

  @doc """
  Returns the datasvc key for the bundle of a stream and subject.
  """
  @spec kv_key(String.t(), String.t()) :: String.t()
  def kv_key(stream_name, subject), do: "zen/rulesets/#{stream_name}/#{subject}.json"

  @doc """
  Returns the stream and subject a bundle key names, the inverse of `kv_key/2`.
  """
  @spec parse_kv_key(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_kv_key("zen/rulesets/" <> rest) do
    case String.split(rest, "/") do
      [stream_name, file] when stream_name != "" -> parse_bundle_file(stream_name, file)
      _ -> :error
    end
  end

  def parse_kv_key(_key), do: :error

  defp parse_bundle_file(stream_name, file) do
    case String.split_at(file, -5) do
      {subject, ".json"} when subject != "" -> {:ok, {stream_name, subject}}
      _ -> :error
    end
  end

  @doc """
  Loads the enabled rules for a stream and subject in evaluation order.
  """
  @spec effective_rules(String.t(), String.t(), keyword()) :: {:ok, [rule()]} | {:error, term()}
  def effective_rules(stream_name, subject, ash_opts) do
    ZenRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(expr(subject == ^subject and stream_name == ^stream_name))
    |> Ash.Query.sort(order: :asc, inserted_at: :asc)
    |> Ash.read(ash_opts)
    |> case do
      {:ok, rules} -> encode_rules(rules)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encodes the bundle document. A bundle with no rules is valid.
  """
  @spec encode(String.t(), String.t(), [rule()]) :: {:ok, String.t()} | {:error, term()}
  def encode(stream_name, subject, rules) when is_list(rules) do
    Jason.encode(%{
      schema: @schema,
      stream_name: stream_name,
      subject: subject,
      rules: Enum.map(rules, fn {key, jdm_json} -> %{key: key, jdm: jdm_json} end),
      digest: digest(stream_name, subject, rules)
    })
  end

  @doc """
  SHA-256 over the schema, stream, subject and each rule's key and JDM text in
  order, every part framed as `<byte length>:<bytes>`.
  """
  @spec digest(String.t(), String.t(), [rule()]) :: String.t()
  def digest(stream_name, subject, rules) when is_list(rules) do
    parts = [@schema, stream_name, subject | Enum.flat_map(rules, &Tuple.to_list/1)]
    framed = Enum.map(parts, &[Integer.to_string(byte_size(&1)), ?:, &1])

    "sha256:" <> Base.encode16(:crypto.hash(:sha256, framed), case: :lower)
  end

  defp encode_rules(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn %ZenRule{name: name, compiled_jdm: jdm}, {:ok, acc} ->
      case Jason.encode(jdm) do
        {:ok, encoded} -> {:cont, {:ok, [{name, encoded} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end
end
