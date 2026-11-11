{build_config, _binding} = Code.eval_file(Path.expand("../.credo.base.exs", __DIR__))
{ex_slop_checks, _binding} = Code.eval_file(Path.expand("../.credo.ex_slop.exs", __DIR__))
{ex_dna_checks, _binding} = Code.eval_file(Path.expand("../.credo.ex_dna.exs", __DIR__))
{jump_checks, _binding} = Code.eval_file(Path.expand("../.credo.jump_checks.exs", __DIR__))

# The console metadata allowlist is defined once, in serviceradar_core's
# ServiceRadar.Logging.ConsoleFormatter; the gateway's logger config selects that formatter
# instead of listing keys, so the metadata check reads the same list from the compiled module.
console_formatter = ServiceRadar.Logging.ConsoleFormatter

unless Code.ensure_loaded?(console_formatter) do
  Code.prepend_path(Path.join(Mix.Project.build_path(), "lib/serviceradar_core/ebin"))
end

logger_metadata_checks = [
  {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig,
   [metadata_keys: console_formatter.printed_keys()]}
]

extra_checks = ex_slop_checks ++ ex_dna_checks ++ jump_checks ++ logger_metadata_checks

build_config.(
  included: ["config/", "lib/", "test/"],
  extra: extra_checks,
  plugins: [{AshCredo, []}],
  requires: ["deps/ex_dna/lib/ex_dna/integrations/credo.ex"]
)
