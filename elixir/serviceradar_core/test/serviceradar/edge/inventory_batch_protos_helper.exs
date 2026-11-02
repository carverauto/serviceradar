# ex_unit_test evaluates this file before it compiles the test sources.
# ExUnit.start/0 has to happen first: `use ExUnit.Case` runs at compile time,
# so a start call inside the test file itself is too late.
ExUnit.start(trace: true)
