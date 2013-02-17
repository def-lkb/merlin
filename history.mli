(** {0 Historique}
  * A sort of zipper: maintains and synchronizes a list of different
  * versions of an object (see ocamlmerlin.ml top comment).
  *)
type 'a t

(* The empty history *)
val empty : 'a t

(** Builds an history from a list.
  * The cursor is set at the beginning: list elements are all in the
  * potential future.
  *)
val of_list : 'a list -> 'a t

(** Splits [--o--] into [--o] [o--] *)
val split : 'a t -> 'a t * 'a t
(** Cut-off the future : [--o--] to [--o] *)
val cutoff : 'a t -> 'a t

(** Element to the left of the cursor
  * (if last operation was an insertion, the inserted value is returned)
  *)
val prev : 'a t -> 'a option

(** Élément to the right of the cursor
  * (often None)
  *)
val next : 'a t -> 'a option

(** Past *)
val prevs : 'a t -> 'a list

(** Potential future *)
val nexts : 'a t -> 'a list

(** offsets are "dates", a number of elements in the past *)
type offset = int
val offset : 'a t -> offset
val seek_offset : offset -> 'a t -> 'a t

(** Moves one step in the future, returning the next element
  * and shifted history (if they exist).
  *
  * If [forward t = Some (e, t')], then [next t = Some e = prev t'].
 *)

val forward  : 'a t -> ('a * 'a t) option 

(** Moves one step in the past, returning the previous element
  * and shifted history (if they exist).
  *
  * If [backward t = Some (e, t')] then [prev t = Some e = next t'].
 *)
val backward : 'a t -> ('a * 'a t) option 

(** Moves an arbitrary number of steps.
  *
  * May stop early if it reaches an end of history.
 *)
val move : int -> 'a t -> 'a t

(** [seek cmp hist] returns a history such that, if [p] and [n] are
  * the previous and next element of history, then both [cmp p >= 0] and
  * [cmp n <= 0] hold.
  *
  * For example, [seek (fun p -> Pervasives.compare p0 p) hist] will
  * move the history to the position [p0], if it exists.
*)
val seek : ('a -> int) -> 'a t -> 'a t

(** Adds an element to the left of the cursor:
  * insert w [..zyx|abc..] = [..zyxw|abc..] *)
val insert : 'a -> 'a t -> 'a t

(** Removes and return the element to the left of the curser, if possible. *)
val remove : 'a t -> ('a * 'a t) option

(** Modifies the element to the left of the cursor. *)
val modify : ('a -> 'a) -> 'a t -> 'a t

(** {1 Synchronization} *)
type 'a sync

module Sync :
sig
  val origin : 'a sync

  val at : 'a t -> 'a sync
  val item : 'a sync -> 'a option

  (* [rewind prj a b] rewinds histories [a] and [b] until it finds
   *  a meeting point, possibly as far as the origin (offset 0).
   *)
  val rewind : ('b -> 'a sync) -> 'a t -> 'b t -> 'a t * 'b t

  (* [nearest prj a b]
   * Finds the point of [a] nearest to the current point of [b]
   *)
  val nearest : ('b -> 'a sync) -> 'a t -> 'b t -> 'a t * 'b t

  val left : ('b -> 'a sync) -> 'a t -> 'b t -> 'a t
  val right : ('b -> 'a sync) -> 'a t -> 'b t -> 'b t
end

(** {1 Misc: integration with the lexer} *)
type pos = Lexing.position
type 'a loc = 'a * pos * pos

val wrap_lexer : ?filter:('a -> bool) -> ?bufpos:Lexing.position ref ->
  'a loc t ref -> (Lexing.lexbuf -> 'a) -> (Lexing.lexbuf -> 'a)

val current_pos : ?default:Lexing.position -> 'a loc t -> pos
val seek_pos : pos -> 'a loc t -> 'a loc t

