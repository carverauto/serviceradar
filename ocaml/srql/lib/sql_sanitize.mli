val escape_string_literal : string -> string
(** [escape_string_literal s] escapes single quotes and backslashes for safe use inside SQL string literals. *)

val is_safe_identifier : string -> bool
(** Returns [true] when the identifier matches [A-Za-z_][A-Za-z0-9_]*. *)

val ensure_safe_identifier : context:string -> string -> string
(** Validate an identifier for the provided [context], raising [Invalid_argument] when it contains unsafe characters. *)

val ensure_safe_expression : context:string -> string -> unit
(** Ensure an arbitrary SQL expression does not contain dangerous metacharacters such as semicolons or SQL comments. *)
