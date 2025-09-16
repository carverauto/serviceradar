(* file: srql/lib/sql_ir.ml *)
type operator = Eq | Neq | Gt | Gte | Lt | Lte | Contains | In | Like | ArrayContains
[@@deriving show]
(* This line auto-generates a print function for debugging *)

type value = String of string | Int of int | Bool of bool | Expr of string | Float of float
[@@deriving show]

type condition =
  | Condition of (string * operator * value)
  | And of condition * condition
  | Or of condition * condition
  | Not of condition
  | Between of string * value * value
  | IsNull of string
  | IsNotNull of string
  | InList of string * value list
[@@deriving show]

type order_dir = Asc | Desc [@@deriving show]

type query = {
  q_type : [ `Select | `Stream ];
  entity : string;
  conditions : condition option;
  limit : int option;
  select_fields : string list option; (* For SELECT queries *)
  order_by : (string * order_dir) list option;
  group_by : string list option;
  having : condition option;
  latest : bool;
}
[@@deriving show]
