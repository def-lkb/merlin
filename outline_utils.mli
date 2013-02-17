(** {0 Outline parser}
 * Auxiliary definitions used by the outline parser *)

type offset = History.offset
type position = Lexing.position

(** Source code constructs are split into "chunks" of different "kinds". *)
type kind =
  | Enter_module (* module _ = struct *)
  | Leave_module (* end *)
  | Definition   (* let / type / … *)
  | Rollback     (* and … : we should go back to the previous definition
                  * to find its "kind" *)
  | Done         (* EOF found after a syntactically correct construction *)
  | Unterminated (* Unfinished syntactic construction *)
  | Syntax_error of Location.t
  | Exception of exn (* The parser raised an exception,
                      * to be handled by the caller *)

(** The outline parser proceeds by side-effects:
  * - most productions have no attached semantic action
  * - when the parser finds a syntactic construct that it knows how to chunk
  *   (above: module or definition), it raises the [Chunk] exception.
  * The associated position is the position of the last token of the
  * chunk, so that, if the parser consumed a lookahead token, it can
  * be recognized and added back to the lexing buffer.
  * EX: let a = 5 type t = ...
  *                  ^ |CHUNK: let a = 5|
  *   The parser raises [Chunk] only after [type], so we must add the
  *   [type] token back to the input stream.
  *)
exception Chunk of kind * position

(** If [!filter_first > 0], the parser will not raise an exception but
  * decrement [filter_first]. This allows to implement rollback when
  * a source code is feed in several separate commands.
  * For example "let x = 5" then "and y = 6" are analyzed as :
  * - "let x = 5" : raise Chunk (Definition,_)
  * - "and …" : raise Chunk (Rollback,_)
  * - filter_first := 1
  *   "let x = 5 and y = 6" : raise Chunk(Definition,_)
  *              ^ no Chunk(Definition) is raised here and
  *                filter_first is decremented
  *)
val filter_first : int ref

(** Used to ignore first-class modules.
  * The construct "let module = … in " allows to define a module
  * locally inside a definition, but our outline parser cannot work
  * inside a definition (it is either correct as a whole,
  * or incorrect).
  * [nesting] is incremented at the beginning of such constructions
  * (here, [let module]) and decremented at its end (here, after the
  * module expression is parsed).No module definition is reported
  * while [!nesting > 0].
  *) 
val nesting : int ref

(** Called to (re)initialize the parser.
  * filter_first := rollback; nesting := 0
  *)
val reset : rollback:int -> unit -> unit

(** Increments [nesting] *)
val enter_sub : unit -> unit
(** Decrements [nesting] *)
val leave_sub : unit -> unit
(** Sends [Chunk] only when [!nesting] is 0 and [!filter_first] is 0 *)
val emit_top : kind -> position -> unit
