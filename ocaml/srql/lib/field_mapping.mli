val map_field_name : entity:string -> string -> string
(** Map user-provided SRQL field names to safe SQL column expressions for the given [entity].
    Raises [Invalid_argument] when the field cannot be mapped to a known identifier. *)
