# generated file - DO NOT EDIT

package(default_visibility = ["//visibility:public"])

# NB: runtime must match executor of target
# so we select on emitter of build host, which matches it
PLATFORM_CONSTRAINT = ["@ocaml//platform/executor:vm"]

config_setting(name = "std?",
               constraint_values = PLATFORM_CONSTRAINT,
               flag_values = {"@ocaml//runtime": "std"})

config_setting(name = "pic?",
               constraint_values = PLATFORM_CONSTRAINT,
               flag_values = {"@ocaml//runtime": "pic"})

config_setting(name = "dbg?",
               constraint_values = PLATFORM_CONSTRAINT,
               flag_values = {"@ocaml//runtime": "dbg"})

config_setting(name = "instrumented?",
               constraint_values = PLATFORM_CONSTRAINT,
               flag_values = {"@ocaml//runtime": "instrumented"})

config_setting(name = "shared?",
               constraint_values = PLATFORM_CONSTRAINT,
               flag_values = {"@ocaml//runtime": "shared"})
