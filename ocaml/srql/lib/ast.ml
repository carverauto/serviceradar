(* file: srql/lib/ast.ml *)
type operator =
  | Eq | Neq | Gt | Gte | Lt | Lte | Contains | In | Like | ArrayContains
  [@@deriving show] (* This line auto-generates a print function for debugging *)

type value =
  | String of string
  | Int of int
  | Bool of bool
  [@@deriving show]

type condition =
  | Condition of (string * operator * value)
  | And of condition * condition
  | Or of condition * condition
  [@@deriving show]

type query = {
  q_type : [ `Show | `Find | `Count | `Select ];
  entity : string;
  conditions : condition option;
  limit : int option;
  select_fields : string list option; (* For SELECT queries *)
} [@@deriving show]
