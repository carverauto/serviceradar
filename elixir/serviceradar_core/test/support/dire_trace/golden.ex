defmodule ServiceRadar.DireTrace.Golden do
  @moduledoc """
  Shared output for the DIRE trace recorders (`ServiceRadar.DireTrace` and
  `ServiceRadar.DireLifecycleTrace`): the committed-copy comparison and the TLA+ value syntax.

  A recorded trace is compared byte for byte with `formal/dire/traces/Trace_<name>.{tla,cfg}`.
  With `DIRE_TRACE_WRITE=1` the files are written instead.
  """

  import ExUnit.Assertions

  @traces_dir Path.expand("../../../../../formal/dire/traces", __DIR__)

  # Resolved at RUNTIME. The compile-time `@traces_dir` is right under plain `mix`, which
  # compiles in place. Under Bazel mix_app compiles in its own build tree and the test runs
  # from `elixir/serviceradar_core` in a sandbox holding only declared runfiles, so the baked
  # path does not exist there; the traces are declared data and sit two levels above the cwd.
  defp traces_dir do
    Enum.find(
      [@traces_dir, Path.expand("../../formal/dire/traces", File.cwd!())],
      @traces_dir,
      &File.dir?/1
    )
  end

  @doc "Compares `Trace_<name>.{tla,cfg}` with the committed copies, or writes them."
  def golden!(name, tla, cfg) do
    golden_file!("Trace_#{name}.tla", tla)
    golden_file!("Trace_#{name}.cfg", cfg)
  end

  @doc "Compares one file under `formal/dire/traces` with its committed copy, or writes it."
  def golden_file!(file, content) do
    traces_dir = traces_dir()
    path = Path.join(traces_dir, file)

    if System.get_env("DIRE_TRACE_WRITE") == "1" do
      File.mkdir_p!(traces_dir)
      File.write!(path, content)
    else
      assert File.read!(path) == content,
             "DIRE trace file #{file} differs from #{path}; the code's behavior changed. " <>
               "Regenerate with DIRE_TRACE_WRITE=1 and model-check it (formal/dire/README.md)."
    end
  end

  @doc "A TLA+ function over `keys`, written with `:>` and `@@`."
  def fun(keys, value_fun) do
    "(" <> Enum.map_join(keys, " @@ ", &"#{str(&1)} :> #{value_fun.(&1)}") <> ")"
  end

  @doc "A TLA+ function from a map, keys in sorted order."
  def fun_map(map, value_fun), do: map |> Map.keys() |> Enum.sort() |> fun(&value_fun.(map[&1]))

  @doc "A TLA+ set of strings, sorted."
  def set(values), do: "{" <> (values |> Enum.sort() |> Enum.map_join(", ", &str/1)) <> "}"

  def str(v), do: ~s("#{v}")

  def tla_bool(true), do: "TRUE"
  def tla_bool(false), do: "FALSE"
end
