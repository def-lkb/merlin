open Std
open Location
open Parsetree
open Raw_parser

type item =
  | Structure of structure
  | Signature of signature
  | Pattern of (Asttypes.label * expression option * pattern)
  | Eval of expression
  | Bindings of Asttypes.rec_flag * value_binding list
  | Newtype of string
  | Functor_argument of string loc * module_type option
  | Open of Asttypes.override_flag * Longident.t loc

type t = Asttypes.rec_flag * item list
let default = Asttypes.Nonrecursive
let empty = default, []
let observe = snd

let functor_arg = function
  | (id, Some mty) ->
    let md = Ast_helper.Md.mk id mty in
    [Signature [Ast_helper.Sig.module_ md]]
  | (id, None) -> []

let rec functor_args acc = function
  | arg :: args -> functor_args (functor_arg arg @ acc) args
  | [] -> acc

let step_nt (type a) is_rec (nt : a nonterminal_class) (v : a) =
  match nt, v with
  | N_rec_flag, r                 -> (r : Asttypes.rec_flag), []
  | N_implementation, str         -> default, [Structure str]
  | N_structure, str              -> default, [Structure str]
  | N_structure_head, str         -> default, [Structure str]
  | N_structure_tail, str         -> default, [Structure str]
  | N_structure_item, str         -> default, [Structure str]
  | N_strict_binding, e           -> default, [Eval e]
  | N_simple_expr, e              -> default, [Eval e]
  | N_seq_expr, e                 -> default, [Eval e]
  | N_opt_default, (Some e)       -> default, [Eval e]
  | N_fun_def, e                  -> default, [Eval e]
  | N_expr, e                     -> default, [Eval e]
  | N_labeled_simple_expr, (_,e)  -> default, [Eval e]
  | N_label_ident, (_,e)          -> default, [Eval e]
  | N_label_expr, (_,e)           -> default, [Eval e]
  | N_let_bindings, e             -> default, [Bindings (is_rec,e)]
  | N_expr_semi_list, el          -> default, List.map (fun e -> Eval e) el
  | N_expr_comma_list, el         -> default, List.map (fun e -> Eval e) el
  | N_interface, sg               -> default, [Signature sg]
  | N_signature_item, sg          -> default, [Signature sg]
  | N_signature, sg               -> default, [Signature (List.rev sg)]
  | N_functor_arg, arg            -> default, functor_arg arg
  | N_functor_args, args          -> default, functor_args [] args
  | N_labeled_simple_pattern, pat -> default, [Pattern pat]
  | N_pattern, pat                -> default, [Pattern ("",None,pat)]
  | N_match_cases, cases          -> default, [Eval (Ast_helper.Exp.function_ cases)]
  | N_match_case,  case           -> default, [Eval (Ast_helper.Exp.function_ [case])]
  | _                             -> empty

let step v (is_rec,_) = match v with
  | T_ _ | Bottom -> empty
  | N_ (nt,v) -> step_nt is_rec nt v

let dump_item ppf = function
  | Structure str -> Printast.implementation ppf str
  | Signature sg -> Printast.interface ppf sg
  | Pattern _ -> ()
  | Eval _ -> ()
  | Bindings _ -> ()
  | Newtype _ -> ()
  | Functor_argument _ -> ()
  | Open _ -> ()

let dump ppf t =
  List.iter (dump_item ppf) (observe t)

let open_implicit_module m env =
  let open Asttypes in
  let lid = {loc = Location.in_file "command line";
             txt = Longident.Lident m } in
  snd (Typemod.type_open_ Override env lid.loc lid)

let fresh_env () =
  (*Ident.reinit();*)
  let initial =
    if Clflags.unsafe_string () then
      Env.initial_unsafe_string
    else
      Env.initial_safe_string in
  let env =
    if Clflags.nopervasives () then
      initial
    else
      open_implicit_module "Pervasives" initial in
  List.fold_right ~f:open_implicit_module
    (Clflags.open_modules ()) ~init:env
