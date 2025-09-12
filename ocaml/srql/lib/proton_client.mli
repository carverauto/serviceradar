(** Proton database client with TLS support for SRQL *)

module Config : sig
  type t = {
    host : string;
    port : int;
    database : string;
    username : string;
    password : string;
    use_tls : bool;
    ca_cert : string option;
    client_cert : string option;
    client_key : string option;
    verify_hostname : bool;
    insecure_skip_verify : bool;
    compression : Proton.Compress.method_t option;
  }

  val default : t
  (** Default configuration for local Proton instance *)

  val with_tls : 
    ?ca_cert:string option ->
    ?client_cert:string option ->
    ?client_key:string option ->
    ?verify_hostname:bool ->
    ?insecure_skip_verify:bool ->
    t -> t
  (** Add TLS configuration to an existing config *)

  val local_docker_tls : t
  (** Pre-configured for local Docker environment with TLS *)
  
  val local_docker_no_tls : t
  (** Pre-configured for local Docker environment without TLS *)
end

module Client : sig
  type t = Proton.Client.t
  (** Represents a Proton database connection *)

  val connect : Config.t -> t Lwt.t
  (** Connect to Proton database with given configuration *)

  val execute : t -> string -> Proton.Client.query_result Lwt.t
  (** Execute a query without returning results *)

  val query : t -> string -> Proton.Client.query_result Lwt.t
  (** Execute a query and return results *)

  val close : t -> unit Lwt.t
  (** Close the connection *)

  val ping : t -> bool Lwt.t
  (** Check if connection is alive *)

  val with_connection : Config.t -> (t -> 'a Lwt.t) -> 'a Lwt.t
  (** Execute a function with a connection, automatically closing it afterwards *)
end

module SRQL : sig
  val translate_and_execute : Client.t -> string -> Proton.Client.query_result Lwt.t
  (** Translate SRQL query to SQL and execute it *)

  val translate_to_sql : string -> string
  (** Translate SRQL query to SQL without executing *)
end