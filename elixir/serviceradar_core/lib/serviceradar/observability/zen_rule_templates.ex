defmodule ServiceRadar.Observability.ZenRuleTemplates do
  @moduledoc """
  Zen rule templates compiled into JSON decision models.

  Templates are data files, not code branches. Packaged defaults live under
  `priv/zen/rules`, and operators can add template directories with
  `SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS`.
  """

  @template_name_regex ~r/^[a-z][a-z0-9_-]*$/

  @spec compile(atom() | String.t() | nil, map()) :: {:ok, map()} | {:error, String.t()}
  def compile(template, _builder_config) do
    with {:ok, name} <- normalize_template_name(template),
         {:ok, path} <- find_template_file(name),
         {:ok, json} <- File.read(path),
         {:ok, compiled} <- Jason.decode(json) do
      {:ok, compiled}
    else
      {:error, :invalid_template_name} ->
        {:error, "invalid Zen rule template name"}

      {:error, :not_found} ->
        {:error, "unsupported Zen rule template"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "invalid Zen rule template JSON: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "failed to load Zen rule template: #{inspect(reason)}"}
    end
  end

  defp normalize_template_name(template) when is_atom(template),
    do: template |> Atom.to_string() |> normalize_template_name()

  defp normalize_template_name(template) when is_binary(template) do
    if Regex.match?(@template_name_regex, template) do
      {:ok, template}
    else
      {:error, :invalid_template_name}
    end
  end

  defp normalize_template_name(_), do: {:error, :invalid_template_name}

  defp find_template_file(name) do
    template_dirs()
    |> Enum.map(&Path.join(&1, "#{name}.json"))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp template_dirs do
    external_template_dirs() ++ [bundled_template_dir()]
  end

  defp external_template_dirs do
    "SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS"
    |> System.get_env("")
    |> String.split(path_separator(), trim: true)
  end

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  defp bundled_template_dir do
    case :code.priv_dir(:serviceradar_core) do
      {:error, _} -> Path.expand("../../../priv/zen/rules", __DIR__)
      priv_dir -> Path.join(to_string(priv_dir), "zen/rules")
    end
  end
end
