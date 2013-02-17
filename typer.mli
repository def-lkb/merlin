(* Maintains a typing environment synchronized with a chunk history *)

type state = Env.t * (Typedtree.structure * Types.signature) list * exn list
type item = Chunk.sync * state
type sync = item History.sync
type t = item History.t

val initial_env : unit -> Env.t
val env : t -> Env.t
val trees : t -> (Typedtree.structure * Types.signature) list
val exns : t -> exn list
val sync : Chunk.t -> t -> t
