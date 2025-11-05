type search_target = Entity of string list | Observable of string | EventClass of string
type time_range = string

type search_filter =
  | AttributeFilter of string * Sql_ir.operator * Sql_ir.value
  | HasAttribute of string
  | AttributeListFilter of string * Sql_ir.value list
  | AttributeListFilterNot of string * Sql_ir.value list
  | ObservableFilter of string * Sql_ir.value
  | TimeFilter of time_range
  | TextSearch of string

type query_spec = {
  targets : search_target list;
  filters : search_filter list;
  aggregations : string list option; (* placeholder *)
  limit : int option;
  sort : (string * Sql_ir.order_dir) list option;
  stream : bool; (* streaming mode *)
  window : string option; (* e.g., 1m, 5m for tumbling windows in streaming *)
  stats : string option; (* e.g., "count() by field" *)
  having : string option; (* e.g., "count()>10" *)
}
