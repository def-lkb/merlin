(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*  Xavier Leroy and Jerome Vouillon, projet Cristal, INRIA Rocquencourt  *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Printing functions *)

open Misc
open Ctype
open Format
open Longident
open Path
open Asttypes
open Types
open Btype
open Outcometree

(* Print a long identifier *)

let rec longident ppf = function
  | Lident s -> pp_print_string ppf s
  | Ldot(p, s) -> fprintf ppf "%a.%s" longident p s
  | Lapply(p1, p2) -> fprintf ppf "%a(%a)" longident p1 longident p2

(* Print an identifier *)

let unique_names = ref Ident.empty

let ident_name id =
  try Ident.find_same id !unique_names with Not_found -> Ident.name id

let add_unique id =
  try ignore (Ident.find_same id !unique_names)
  with Not_found ->
    unique_names := Ident.add id (Ident.unique_toplevel_name id) !unique_names

let ident ppf id = pp_print_string ppf (ident_name id)

(* Print a path *)

let printing_env = ref Env.empty

let ident_stdlib = Ident.create_persistent "Stdlib"
let non_shadowed_pervasive = function
  | Pdot(Pident id, _, _)
  | Pdot(Pdot (Pident id, "Pervasives", _), _, _) ->
      Ident.same id ident_stdlib
  | _ -> false

let find_double_underscore s =
  let len = String.length s in
  let rec loop i =
    if i + 1 >= len then
      None
    else if s.[i] = '_' && s.[i + 1] = '_' then
      Some i
    else
      loop (i + 1)
  in
  loop 0

let rec module_path_is_an_alias_of env path ~alias_of =
  match Env.find_module path env with
  | { md_type = Mty_alias (_, path'); _ } ->
    Path.same path' alias_of ||
    module_path_is_an_alias_of env path' ~alias_of
  | _ -> false
  | exception Not_found -> false

(* Simple heuristic to print Foo__bar.* as Foo.Bar.* when Foo.Bar is an alias
   for Foo__bar. This pattern is used by the stdlib. *)
let rec rewrite_double_underscore_paths env p =
  match p with
  | Pdot (p, s, n) ->
    Pdot (rewrite_double_underscore_paths env p, s, n)
  | Papply (a, b) ->
    Papply (rewrite_double_underscore_paths env a,
            rewrite_double_underscore_paths env b)
  | Pident id ->
    let name = Ident.name id in
    match find_double_underscore name with
    | None -> p
    | Some i ->
      let better_lid =
        Ldot
          (Lident (String.sub name 0 i),
           String.capitalize_ascii
             (String.sub name (i + 2) (String.length name - i - 2)))
      in
      match Env.lookup_module ~load:true better_lid env with
      | exception Not_found -> p
      | p' ->
        if module_path_is_an_alias_of env p' ~alias_of:p then
          p'
        else
          p

let rewrite_double_underscore_paths env p =
  if env == Env.empty then
    p
  else
    rewrite_double_underscore_paths env p

let rec tree_of_path = function
  | Pident id ->
      Oide_ident (ident_name id)
  | Pdot(_, s, _pos) as path
    when non_shadowed_pervasive path ->
      Oide_ident s
  | Pdot(p, s, _pos) ->
      Oide_dot (tree_of_path p, s)
  | Papply(p1, p2) ->
    Oide_apply (tree_of_path p1,
                tree_of_path p2)

let rec path ppf = function
  | Pident id ->
      ident ppf id
  | Pdot(_, s, _pos) as path
    when non_shadowed_pervasive path ->
      pp_print_string ppf s
  | Pdot(p, s, _pos) ->
      path ppf p;
      pp_print_char ppf '.';
      pp_print_string ppf s
  | Papply(p1, p2) ->
      fprintf ppf "%a(%a)" path p1 path p2

let tree_of_path p =
  tree_of_path (rewrite_double_underscore_paths !printing_env p)
let path ppf p =
  path ppf (rewrite_double_underscore_paths !printing_env p)

let rec string_of_out_ident = function
  | Oide_ident s -> s
  | Oide_dot (id, s) -> String.concat "." [string_of_out_ident id; s]
  | Oide_apply (id1, id2) ->
      String.concat ""
        [string_of_out_ident id1; "("; string_of_out_ident id2; ")"]

let string_of_path p = string_of_out_ident (tree_of_path p)

(* Print a recursive annotation *)

let tree_of_rec = function
  | Trec_not -> Orec_not
  | Trec_first -> Orec_first
  | Trec_next -> Orec_next

(* Print a raw type expression, with sharing *)

let raw_list pr ppf = function
    [] -> fprintf ppf "[]"
  | a :: l ->
      fprintf ppf "@[<1>[%a%t]@]" pr a
        (fun ppf -> List.iter (fun x -> fprintf ppf ";@,%a" pr x) l)

let kind_vars = ref []
let kind_count = ref 0

let rec safe_kind_repr v = function
    Fvar {contents=Some k}  ->
      if List.memq k v then "Fvar loop" else
      safe_kind_repr (k::v) k
  | Fvar r ->
      let vid =
        try List.assq r !kind_vars
        with Not_found ->
          let c = incr kind_count; !kind_count in
          kind_vars := (r,c) :: !kind_vars;
          c
      in
      Printf.sprintf "Fvar {None}@%d" vid
  | Fpresent -> "Fpresent"
  | Fabsent -> "Fabsent"

let rec safe_commu_repr v = function
    Cok -> "Cok"
  | Cunknown -> "Cunknown"
  | Clink r ->
      if List.memq r v then "Clink loop" else
      safe_commu_repr (r::v) !r

let rec safe_repr v = function
    {desc = Tlink t} when not (List.memq t v) ->
      safe_repr (t::v) t
  | t -> t

let rec list_of_memo = function
    Mnil -> []
  | Mcons (_priv, p, _t1, _t2, rem) -> p :: list_of_memo rem
  | Mlink rem -> list_of_memo !rem

let print_name ppf = function
    None -> fprintf ppf "None"
  | Some name -> fprintf ppf "\"%s\"" name

let string_of_label = function
    Nolabel -> ""
  | Labelled s -> s
  | Optional s -> "?"^s

let visited = ref []
let rec raw_type ppf ty =
  let ty = safe_repr [] ty in
  if List.memq ty !visited then fprintf ppf "{id=%d}" ty.id else begin
    visited := ty :: !visited;
    fprintf ppf "@[<1>{id=%d;level=%d;desc=@,%a}@]" ty.id ty.level
      raw_type_desc ty.desc
  end
and raw_type_list tl = raw_list raw_type tl
and raw_type_desc ppf = function
    Tvar name -> fprintf ppf "Tvar %a" print_name name
  | Tarrow(l,t1,t2,c) ->
      fprintf ppf "@[<hov1>Tarrow(\"%s\",@,%a,@,%a,@,%s)@]"
        (string_of_label l) raw_type t1 raw_type t2
        (safe_commu_repr [] c)
  | Ttuple tl ->
      fprintf ppf "@[<1>Ttuple@,%a@]" raw_type_list tl
  | Tconstr (p, tl, abbrev) ->
      fprintf ppf "@[<hov1>Tconstr(@,%a,@,%a,@,%a)@]" path p
        raw_type_list tl
        (raw_list path) (list_of_memo !abbrev)
  | Tobject (t, nm) ->
      fprintf ppf "@[<hov1>Tobject(@,%a,@,@[<1>ref%t@])@]" raw_type t
        (fun ppf ->
          match !nm with None -> fprintf ppf " None"
          | Some(p,tl) ->
              fprintf ppf "(Some(@,%a,@,%a))" path p raw_type_list tl)
  | Tfield (f, k, t1, t2) ->
      fprintf ppf "@[<hov1>Tfield(@,%s,@,%s,@,%a,@;<0 -1>%a)@]" f
        (safe_kind_repr [] k)
        raw_type t1 raw_type t2
  | Tnil -> fprintf ppf "Tnil"
  | Tlink t -> fprintf ppf "@[<1>Tlink@,%a@]" raw_type t
  | Tsubst t -> fprintf ppf "@[<1>Tsubst@,%a@]" raw_type t
  | Tunivar name -> fprintf ppf "Tunivar %a" print_name name
  | Tpoly (t, tl) ->
      fprintf ppf "@[<hov1>Tpoly(@,%a,@,%a)@]"
        raw_type t
        raw_type_list tl
  | Tvariant row ->
      fprintf ppf
        "@[<hov1>{@[%s@,%a;@]@ @[%s@,%a;@]@ %s%b;@ %s%b;@ @[<1>%s%t@]}@]"
        "row_fields="
        (raw_list (fun ppf (l, f) ->
          fprintf ppf "@[%s,@ %a@]" l raw_field f))
        row.row_fields
        "row_more=" raw_type row.row_more
        "row_closed=" row.row_closed
        "row_fixed=" row.row_fixed
        "row_name="
        (fun ppf ->
          match row.row_name with None -> fprintf ppf "None"
          | Some(p,tl) ->
              fprintf ppf "Some(@,%a,@,%a)" path p raw_type_list tl)
  | Tpackage (p, _, tl) ->
      fprintf ppf "@[<hov1>Tpackage(@,%a@,%a)@]" path p
        raw_type_list tl

and raw_field ppf = function
    Rpresent None -> fprintf ppf "Rpresent None"
  | Rpresent (Some t) -> fprintf ppf "@[<1>Rpresent(Some@,%a)@]" raw_type t
  | Reither (c,tl,m,e) ->
      fprintf ppf "@[<hov1>Reither(%b,@,%a,@,%b,@,@[<1>ref%t@])@]" c
        raw_type_list tl m
        (fun ppf ->
          match !e with None -> fprintf ppf " None"
          | Some f -> fprintf ppf "@,@[<1>(%a)@]" raw_field f)
  | Rabsent -> fprintf ppf "Rabsent"

let raw_type_expr ppf t =
  visited := []; kind_vars := []; kind_count := 0;
  raw_type ppf t;
  visited := []; kind_vars := []

let () = Btype.print_raw := raw_type_expr

(* Normalize paths *)

let printing_env = ref Env.empty

let same_type t t' = repr t == repr t'

let set_printing_env env =
  printing_env :=
    if !Clflags.real_paths then Env.empty
    else env

let wrap_printing_env env f =
  set_printing_env (Env.update_short_paths env);
  try_finally f ~always:(fun () -> set_printing_env Env.empty)

type type_result = Short_paths.type_result =
  | Nth of int
  | Path of int list option * Path.t

type type_resolution = Short_paths.type_resolution =
  | Nth of int
  | Subst of int list
  | Id

let apply_subst ns args =
  List.map (List.nth args) ns

let apply_subst_opt nso args =
  match nso with
  | None -> args
  | Some ns -> apply_subst ns args

let apply_nth n args =
  List.nth args n

let best_type_path p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then Path(None, p)
  else Short_paths.find_type (Env.short_paths !printing_env) p

let best_type_path_resolution p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then Id
  else Short_paths.find_type_resolution (Env.short_paths !printing_env) p

let best_type_path_simple p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then p
  else Short_paths.find_type_simple (Env.short_paths !printing_env) p

let best_module_type_path p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then p
  else Short_paths.find_module_type (Env.short_paths !printing_env) p

let best_module_path p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then p
  else Short_paths.find_module (Env.short_paths !printing_env) p

let best_class_type_path p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then None, p
  else Short_paths.find_class_type (Env.short_paths !printing_env) p

let best_class_type_path_simple p =
  if !Clflags.real_paths || !printing_env == Env.empty
  then p
  else Short_paths.find_class_type_simple (Env.short_paths !printing_env) p

(* Print a type expression *)

let names = ref ([] : (type_expr * string) list)
let name_counter = ref 0
let named_vars = ref ([] : string list)

let reset_names () = names := []; name_counter := 0; named_vars := []
let add_named_var ty =
  match ty.desc with
    Tvar (Some name) | Tunivar (Some name) ->
      if List.mem name !named_vars then () else
      named_vars := name :: !named_vars
  | _ -> ()

let rec new_name () =
  let name =
    if !name_counter < 26
    then String.make 1 (Char.chr(97 + !name_counter))
    else String.make 1 (Char.chr(97 + !name_counter mod 26)) ^
           string_of_int(!name_counter / 26) in
  incr name_counter;
  if List.mem name !named_vars
  || List.exists (fun (_, name') -> name = name') !names
  then new_name ()
  else name

let name_of_type t =
  (* We've already been through repr at this stage, so t is our representative
     of the union-find class. *)
  try List.assq t !names with Not_found ->
    let name =
      match t.desc with
        Tvar (Some name) | Tunivar (Some name) ->
          (* Some part of the type we've already printed has assigned another
           * unification variable to that name. We want to keep the name, so try
           * adding a number until we find a name that's not taken. *)
          let current_name = ref name in
          let i = ref 0 in
          while List.exists (fun (_, name') -> !current_name = name') !names do
            current_name := name ^ (string_of_int !i);
            i := !i + 1;
          done;
          !current_name
      | _ ->
          (* No name available, create a new one *)
          new_name ()
    in
    (* Exception for type declarations *)
    if name <> "_" then names := (t, name) :: !names;
    name

let check_name_of_type t = ignore(name_of_type t)

let remove_names tyl =
  let tyl = List.map repr tyl in
  names := List.filter (fun (ty,_) -> not (List.memq ty tyl)) !names

let visited_objects = ref ([] : type_expr list)
let aliased = ref ([] : type_expr list)
let delayed = ref ([] : type_expr list)

let add_delayed t =
  if not (List.memq t !delayed) then delayed := t :: !delayed

let is_aliased ty = List.memq (proxy ty) !aliased
let add_alias ty =
  let px = proxy ty in
  if not (is_aliased px) then begin
    aliased := px :: !aliased;
    add_named_var px
  end

let aliasable ty =
  match ty.desc with
    Tvar _ | Tunivar _ | Tpoly _ -> false
  | Tconstr (p, _, _) -> begin
      match best_type_path_resolution p with
      | Nth _ -> false
      | Subst _ | Id -> true
    end
  | _ -> true

let namable_row row =
  row.row_name <> None &&
  List.for_all
    (fun (_, f) ->
       match row_field_repr f with
       | Reither(c, l, _, _) ->
           row.row_closed && if c then l = [] else List.length l = 1
       | _ -> true)
    row.row_fields

let rec mark_loops_rec visited ty =
  let ty = repr ty in
  let px = proxy ty in
  if List.memq px visited && aliasable ty then add_alias px else
    let visited = px :: visited in
    match ty.desc with
    | Tvar _ -> add_named_var ty
    | Tarrow(_, ty1, ty2, _) ->
        mark_loops_rec visited ty1; mark_loops_rec visited ty2
    | Ttuple tyl -> List.iter (mark_loops_rec visited) tyl
    | Tconstr(p, tyl, _) -> begin
        match best_type_path_resolution p with
        | Nth n ->
            mark_loops_rec visited (apply_nth n tyl)
        | Subst ns ->
            List.iter (mark_loops_rec visited) (apply_subst ns tyl)
        | Id ->
            List.iter (mark_loops_rec visited) tyl
      end
    | Tpackage (_, _, tyl) ->
        List.iter (mark_loops_rec visited) tyl
    | Tvariant row ->
        if List.memq px !visited_objects then add_alias px else
         begin
          let row = row_repr row in
          if not (static_row row) then
            visited_objects := px :: !visited_objects;
          match row.row_name with
          | Some(_p, tyl) when namable_row row ->
              List.iter (mark_loops_rec visited) tyl
          | _ ->
              iter_row (mark_loops_rec visited) row
         end
    | Tobject (fi, nm) ->
        if List.memq px !visited_objects then add_alias px else
         begin
          if opened_object ty then
            visited_objects := px :: !visited_objects;
          begin match !nm with
          | None ->
              let fields, _ = flatten_fields fi in
              List.iter
                (fun (_, kind, ty) ->
                  if field_kind_repr kind = Fpresent then
                    mark_loops_rec visited ty)
                fields
          | Some (_, l) ->
              List.iter (mark_loops_rec visited) (List.tl l)
          end
        end
    | Tfield(_, kind, ty1, ty2) when field_kind_repr kind = Fpresent ->
        mark_loops_rec visited ty1; mark_loops_rec visited ty2
    | Tfield(_, _, _, ty2) ->
        mark_loops_rec visited ty2
    | Tnil -> ()
    | Tsubst ty -> mark_loops_rec visited ty
    | Tlink _ -> fatal_error "Printtyp.mark_loops_rec (2)"
    | Tpoly (ty, tyl) ->
        List.iter (fun t -> add_alias t) tyl;
        mark_loops_rec visited ty
    | Tunivar _ -> add_named_var ty

let mark_loops ty =
  normalize_type Env.empty ty;
  mark_loops_rec [] ty;;

let reset_loop_marks () =
  visited_objects := []; aliased := []; delayed := []

let reset () =
  unique_names := Ident.empty; reset_names (); reset_loop_marks ()

let reset_and_mark_loops ty =
  reset (); mark_loops ty

let reset_and_mark_loops_list tyl =
  reset (); List.iter mark_loops tyl

(* Disabled in classic mode when printing an unification error *)
let print_labels = ref true

let rec tree_of_typexp sch ty =
  let ty = repr ty in
  let px = proxy ty in
  if List.mem_assq px !names && not (List.memq px !delayed) then
   let mark = is_non_gen sch ty in
   Otyp_var (mark, name_of_type px) else

  let pr_typ () =
    match ty.desc with
    | Tvar _ ->
        (*let lev =
          if is_non_gen sch ty then "/" ^ string_of_int ty.level else "" in*)
        Otyp_var (is_non_gen sch ty, name_of_type ty)
    | Tarrow(l, ty1, ty2, _) ->
        let pr_arrow l ty1 ty2 =
          let lab =
            if !print_labels || is_optional l then string_of_label l else ""
          in
          let t1 =
            if is_optional l then
              match (repr ty1).desc with
              | Tconstr(path, [ty], _)
                when Path.same path Predef.path_option ->
                  tree_of_typexp sch ty
              | _ -> Otyp_stuff "<hidden>"
            else tree_of_typexp sch ty1 in
          Otyp_arrow (lab, t1, tree_of_typexp sch ty2) in
        pr_arrow l ty1 ty2
    | Ttuple tyl ->
        Otyp_tuple (tree_of_typlist sch tyl)
    | Tconstr(p, tyl, _abbrev) -> begin
        match best_type_path p with
        | Nth n -> tree_of_typexp sch (apply_nth n tyl)
        | Path(nso, p) ->
            let tyl = apply_subst_opt nso tyl in
            Otyp_constr (tree_of_path p, tree_of_typlist sch tyl)
      end
    | Tvariant row ->
        let row = row_repr row in
        let fields =
          if row.row_closed then
            List.filter (fun (_, f) -> row_field_repr f <> Rabsent)
              row.row_fields
          else row.row_fields in
        let present =
          List.filter
            (fun (_, f) ->
               match row_field_repr f with
               | Rpresent _ -> true
               | _ -> false)
            fields in
        let all_present = List.length present = List.length fields in
        begin match row.row_name with
        | Some(p, tyl) when namable_row row ->
            let out_variant =
              match best_type_path p with
              | Nth n -> tree_of_typexp sch (apply_nth n tyl)
              | Path(nso, p) ->
                  let id = tree_of_path p in
                  let args = tree_of_typlist sch (apply_subst_opt nso tyl) in
                  Otyp_constr (id, args)
            in
            if row.row_closed && all_present then
              out_variant
            else
              let non_gen = is_non_gen sch px in
              let tags =
                if all_present then None else Some (List.map fst present) in
              Otyp_variant (non_gen, Ovar_typ out_variant, row.row_closed, tags)
        | _ ->
            let non_gen =
              not (row.row_closed && all_present) && is_non_gen sch px in
            let fields = List.map (tree_of_row_field sch) fields in
            let tags =
              if all_present then None else Some (List.map fst present) in
            Otyp_variant (non_gen, Ovar_fields fields, row.row_closed, tags)
        end
    | Tobject (fi, nm) ->
        tree_of_typobject sch fi !nm
    | Tnil | Tfield _ ->
        tree_of_typobject sch ty None
    | Tsubst ty ->
        tree_of_typexp sch ty
    | Tlink _ ->
        fatal_error "Printtyp.tree_of_typexp"
    | Tpoly (ty, []) ->
        tree_of_typexp sch ty
    | Tpoly (ty, tyl) ->
        (*let print_names () =
          List.iter (fun (_, name) -> prerr_string (name ^ " ")) !names;
          prerr_string "; " in *)
        let tyl = List.map repr tyl in
        if tyl = [] then tree_of_typexp sch ty else begin
          let old_delayed = !delayed in
          (* Make the names delayed, so that the real type is
             printed once when used as proxy *)
          List.iter add_delayed tyl;
          let tl = List.map name_of_type tyl in
          let tr = Otyp_poly (tl, tree_of_typexp sch ty) in
          (* Forget names when we leave scope *)
          remove_names tyl;
          delayed := old_delayed; tr
        end
    | Tunivar _ ->
        Otyp_var (false, name_of_type ty)
    | Tpackage (p, n, tyl) ->
        let p = best_module_type_path p in
        let n =
          List.map (fun li -> String.concat "." (Longident.flatten li)) n in
        Otyp_module (Path.name p, n, tree_of_typlist sch tyl)
  in
  if List.memq px !delayed then delayed := List.filter ((!=) px) !delayed;
  if is_aliased px && aliasable ty then begin
    check_name_of_type px;
    Otyp_alias (pr_typ (), name_of_type px) end
  else pr_typ ()

and tree_of_row_field sch (l, f) =
  match row_field_repr f with
  | Rpresent None | Reither(true, [], _, _) -> (l, false, [])
  | Rpresent(Some ty) -> (l, false, [tree_of_typexp sch ty])
  | Reither(c, tyl, _, _) ->
      if c (* contradiction: constant constructor with an argument *)
      then (l, true, tree_of_typlist sch tyl)
      else (l, false, tree_of_typlist sch tyl)
  | Rabsent -> (l, false, [] (* actually, an error *))

and tree_of_typlist sch tyl =
  List.map (tree_of_typexp sch) tyl

and tree_of_typobject sch fi nm =
  begin match nm with
  | None ->
      let pr_fields fi =
        let (fields, rest) = flatten_fields fi in
        let present_fields =
          List.fold_right
            (fun (n, k, t) l ->
               match field_kind_repr k with
               | Fpresent -> (n, t) :: l
               | _ -> l)
            fields [] in
        let sorted_fields =
          List.sort
            (fun (n, _) (n', _) -> String.compare n n')
            present_fields
        in
        tree_of_typfields sch rest sorted_fields in
      let (fields, rest) = pr_fields fi in
      Otyp_object (fields, rest)
  | Some (p, ty :: tyl) -> begin
      let non_gen = is_non_gen sch (repr ty) in
      let args = tree_of_typlist sch tyl in
      let p = best_type_path_simple p in
      Otyp_class (non_gen, tree_of_path p, args)
    end
  | _ ->
      fatal_error "Printtyp.tree_of_typobject"
  end

and is_non_gen sch ty =
    sch && is_Tvar ty && ty.level <> generic_level

and tree_of_typfields sch rest = function
  | [] ->
      let rest =
        match rest.desc with
        | Tvar _ | Tunivar _ -> Some (is_non_gen sch rest)
        | Tconstr _ -> Some false
        | Tnil -> None
        | _ -> fatal_error "typfields (1)"
      in
      ([], rest)
  | (s, t) :: l ->
      let field = (s, tree_of_typexp sch t) in
      let (fields, rest) = tree_of_typfields sch rest l in
      (field :: fields, rest)

let typexp sch ppf ty =
  !Oprint.out_type ppf (tree_of_typexp sch ty)

let type_expr ppf ty = typexp false ppf ty

and type_sch ppf ty = typexp true ppf ty

and type_scheme ppf ty = reset_and_mark_loops ty; typexp true ppf ty

let type_expansion ppf ty1 ty2 =
  let tree1 = tree_of_typexp false ty1 in
  let tree2 = tree_of_typexp false ty2 in
  let pp = !Oprint.out_type in
  if tree1 = tree2 then
    pp ppf tree1
  else
    fprintf ppf "@[<2>%a@ =@ %a@]" pp tree1 pp tree2

(* Maxence *)
let type_scheme_max ?(b_reset_names=true) ppf ty =
  if b_reset_names then reset_names () ;
  typexp true ppf ty
(* End Maxence *)

let tree_of_type_scheme ty = reset_and_mark_loops ty; tree_of_typexp true ty

(* Print one type declaration *)

let tree_of_constraints params =
  List.fold_right
    (fun ty list ->
       let ty' = unalias ty in
       if proxy ty != proxy ty' then
         let tr = tree_of_typexp true ty in
         (tr, tree_of_typexp true ty') :: list
       else list)
    params []

let filter_params tyl =
  let params =
    List.fold_left
      (fun tyl ty ->
        let ty = repr ty in
        if List.memq ty tyl then Btype.newgenty (Tsubst ty) :: tyl
        else ty :: tyl)
      [] tyl
  in List.rev params

let mark_loops_constructor_arguments = function
  | Cstr_tuple l -> List.iter mark_loops l
  | Cstr_record l -> List.iter (fun l -> mark_loops l.ld_type) l

let rec tree_of_type_decl id decl =

  reset();

  let params = filter_params decl.type_params in

  begin match decl.type_manifest with
  | Some ty ->
      let vars = free_variables ty in
      List.iter
        (function {desc = Tvar (Some "_")} as ty ->
            if List.memq ty vars then ty.desc <- Tvar None
          | _ -> ())
        params
  | None -> ()
  end;

  List.iter add_alias params;
  List.iter mark_loops params;
  List.iter check_name_of_type (List.map proxy params);
  let ty_manifest =
    match decl.type_manifest with
    | None -> None
    | Some ty ->
        let ty =
          (* Special hack to hide variant name *)
          match repr ty with {desc=Tvariant row} ->
            let row = row_repr row in
            begin match row.row_name with
              Some (Pident id', _) when Ident.same id id' ->
                newgenty (Tvariant {row with row_name = None})
            | _ -> ty
            end
          | _ -> ty
        in
        mark_loops ty;
        Some ty
  in
  begin match decl.type_kind with
  | Type_abstract -> ()
  | Type_variant cstrs ->
      List.iter
        (fun c ->
           mark_loops_constructor_arguments c.cd_args;
           may mark_loops c.cd_res)
        cstrs
  | Type_record(l, _rep) ->
      List.iter (fun l -> mark_loops l.ld_type) l
  | Type_open -> ()
  end;

  let type_param =
    function
    | Otyp_var (_, id) -> id
    | _ -> "?"
  in
  let type_defined decl =
    let abstr =
      match decl.type_kind with
        Type_abstract ->
          decl.type_manifest = None || decl.type_private = Private
      | Type_record _ ->
          decl.type_private = Private
      | Type_variant tll ->
          decl.type_private = Private ||
          List.exists (fun cd -> cd.cd_res <> None) tll
      | Type_open ->
          decl.type_manifest = None
    in
    let vari =
      List.map2
        (fun ty v ->
          if abstr || not (is_Tvar (repr ty)) then Variance.get_upper v
          else (true,true))
        decl.type_params decl.type_variance
    in
    (Ident.name id,
     List.map2 (fun ty cocn -> type_param (tree_of_typexp false ty), cocn)
       params vari)
  in
  let tree_of_manifest ty1 =
    match ty_manifest with
    | None -> ty1
    | Some ty -> Otyp_manifest (tree_of_typexp false ty, ty1)
  in
  let (name, args) = type_defined decl in
  let constraints = tree_of_constraints params in
  let ty, priv =
    match decl.type_kind with
    | Type_abstract ->
        begin match ty_manifest with
        | None -> (Otyp_abstract, Public)
        | Some ty ->
            tree_of_typexp false ty, decl.type_private
        end
    | Type_variant cstrs ->
        tree_of_manifest (Otyp_sum (List.map tree_of_constructor cstrs)),
        decl.type_private
    | Type_record(lbls, _rep) ->
        tree_of_manifest (Otyp_record (List.map tree_of_label lbls)),
        decl.type_private
    | Type_open ->
        tree_of_manifest Otyp_open,
        Public
  in
  let immediate =
    Builtin_attributes.immediate decl.type_attributes
  in
    { otype_name = name;
      otype_params = args;
      otype_type = ty;
      otype_private = priv;
      otype_immediate = immediate;
      otype_unboxed = decl.type_unboxed.unboxed;
      otype_cstrs = constraints }

and tree_of_constructor_arguments = function
  | Cstr_tuple l -> tree_of_typlist false l
  | Cstr_record l -> [ Otyp_record (List.map tree_of_label l) ]

and tree_of_constructor cd =
  let name = Ident.name cd.cd_id in
  let arg () = tree_of_constructor_arguments cd.cd_args in
  match cd.cd_res with
  | None -> (name, arg (), None)
  | Some res ->
      let nm = !names in
      names := [];
      let ret = tree_of_typexp false res in
      let args = arg () in
      names := nm;
      (name, args, Some ret)

and tree_of_label l =
  (Ident.name l.ld_id, l.ld_mutable = Mutable, tree_of_typexp false l.ld_type)

let tree_of_type_declaration id decl rs =
  Osig_type (tree_of_type_decl id decl, tree_of_rec rs)

let type_declaration id ppf decl =
  !Oprint.out_sig_item ppf (tree_of_type_declaration id decl Trec_first)

let constructor_arguments ppf a =
  let tys = tree_of_constructor_arguments a in
  !Oprint.out_type ppf (Otyp_tuple tys)

(* Print an extension declaration *)

let tree_of_extension_constructor id ext es =
  reset ();
  let type_path = best_type_path_simple ext.ext_type_path in
  let ty_name = Path.name type_path in
  let ty_params = filter_params ext.ext_type_params in
  List.iter add_alias ty_params;
  List.iter mark_loops ty_params;
  List.iter check_name_of_type (List.map proxy ty_params);
  mark_loops_constructor_arguments ext.ext_args;
  may mark_loops ext.ext_ret_type;
  let type_param =
    function
    | Otyp_var (_, id) -> id
    | _ -> "?"
  in
  let ty_params =
    List.map (fun ty -> type_param (tree_of_typexp false ty)) ty_params
  in
  let name = Ident.name id in
  let args, ret =
    match ext.ext_ret_type with
    | None -> (tree_of_constructor_arguments ext.ext_args, None)
    | Some res ->
        let nm = !names in
        names := [];
        let ret = tree_of_typexp false res in
        let args = tree_of_constructor_arguments ext.ext_args in
        names := nm;
        (args, Some ret)
  in
  let ext =
    { oext_name = name;
      oext_type_name = ty_name;
      oext_type_params = ty_params;
      oext_args = args;
      oext_ret_type = ret;
      oext_private = ext.ext_private }
  in
  let es =
    match es with
        Text_first -> Oext_first
      | Text_next -> Oext_next
      | Text_exception -> Oext_exception
  in
    Osig_typext (ext, es)

let extension_constructor id ppf ext =
  !Oprint.out_sig_item ppf (tree_of_extension_constructor id ext Text_first)

(* Print a value declaration *)

let tree_of_value_description id decl =
  (* Format.eprintf "@[%a@]@." raw_type_expr decl.val_type; *)
  let id = Ident.name id in
  let ty = tree_of_type_scheme decl.val_type in
  let vd =
    { oval_name = id;
      oval_type = ty;
      oval_prims = [];
      oval_attributes = [] }
  in
  let vd =
    match decl.val_kind with
    | Val_prim p -> Primitive.print p vd
    | _ -> vd
  in
  Osig_value vd

let value_description id ppf decl =
  !Oprint.out_sig_item ppf (tree_of_value_description id decl)

(* Print a class type *)

let method_type (_, kind, ty) =
  match field_kind_repr kind, repr ty with
    Fpresent, {desc=Tpoly(ty, tyl)} -> (ty, tyl)
  | _       , ty                    -> (ty, [])

let tree_of_metho sch concrete csil (lab, kind, ty) =
  if lab <> dummy_method then begin
    let kind = field_kind_repr kind in
    let priv = kind <> Fpresent in
    let virt = not (Concr.mem lab concrete) in
    let (ty, tyl) = method_type (lab, kind, ty) in
    let tty = tree_of_typexp sch ty in
    remove_names tyl;
    Ocsg_method (lab, priv, virt, tty) :: csil
  end
  else csil

let rec prepare_class_type params = function
  | Cty_constr (_p, tyl, cty) ->
      let sty = Ctype.self_type cty in
      if List.memq (proxy sty) !visited_objects
      || not (List.for_all is_Tvar params)
      || List.exists (deep_occur sty) tyl
      then prepare_class_type params cty
      else List.iter mark_loops tyl
  | Cty_signature sign ->
      let sty = repr sign.csig_self in
      (* Self may have a name *)
      let px = proxy sty in
      if List.memq px !visited_objects then add_alias sty
      else visited_objects := px :: !visited_objects;
      let (fields, _) =
        Ctype.flatten_fields (Ctype.object_fields sign.csig_self)
      in
      List.iter (fun met -> mark_loops (fst (method_type met))) fields;
      Vars.iter (fun _ (_, _, ty) -> mark_loops ty) sign.csig_vars
  | Cty_arrow (_, ty, cty) ->
      mark_loops ty;
      prepare_class_type params cty

let rec tree_of_class_type sch params =
  function
  | Cty_constr (p, tyl, cty) ->
      let sty = Ctype.self_type cty in
      if List.memq (proxy sty) !visited_objects
      || not (List.for_all is_Tvar params)
      then
        tree_of_class_type sch params cty
      else begin
        let nso, p = best_class_type_path p in
        let tyl = apply_subst_opt nso tyl in
        Octy_constr (tree_of_path p, tree_of_typlist true tyl)
      end
  | Cty_signature sign ->
      let sty = repr sign.csig_self in
      let self_ty =
        if is_aliased sty then
          Some (Otyp_var (false, name_of_type (proxy sty)))
        else None
      in
      let (fields, _) =
        Ctype.flatten_fields (Ctype.object_fields sign.csig_self)
      in
      let csil = [] in
      let csil =
        List.fold_left
          (fun csil (ty1, ty2) -> Ocsg_constraint (ty1, ty2) :: csil)
          csil (tree_of_constraints params)
      in
      let all_vars =
        Vars.fold (fun l (m, v, t) all -> (l, m, v, t) :: all) sign.csig_vars []
      in
      (* Consequence of PR#3607: order of Map.fold has changed! *)
      let all_vars = List.rev all_vars in
      let csil =
        List.fold_left
          (fun csil (l, m, v, t) ->
            Ocsg_value (l, m = Mutable, v = Virtual, tree_of_typexp sch t)
            :: csil)
          csil all_vars
      in
      let csil =
        List.fold_left (tree_of_metho sch sign.csig_concr) csil fields
      in
      Octy_signature (self_ty, List.rev csil)
  | Cty_arrow (l, ty, cty) ->
      let lab =
        if !print_labels || is_optional l then string_of_label l else ""
      in
      let ty =
       if is_optional l then
         match (repr ty).desc with
         | Tconstr(path, [ty], _) when Path.same path Predef.path_option -> ty
         | _ -> newconstr (Path.Pident(Ident.create "<hidden>")) []
       else ty in
      let tr = tree_of_typexp sch ty in
      Octy_arrow (lab, tr, tree_of_class_type sch params cty)

let class_type ppf cty =
  reset ();
  prepare_class_type [] cty;
  !Oprint.out_class_type ppf (tree_of_class_type false [] cty)

let tree_of_class_param param variance =
  (match tree_of_typexp true param with
    Otyp_var (_, s) -> s
  | _ -> "?"),
  if is_Tvar (repr param) then (true, true) else variance

let class_variance =
  List.map Variance.(fun v -> mem May_pos v, mem May_neg v)

let tree_of_class_declaration id cl rs =
  let params = filter_params cl.cty_params in

  reset ();
  List.iter add_alias params;
  prepare_class_type params cl.cty_type;
  let sty = Ctype.self_type cl.cty_type in
  List.iter mark_loops params;

  List.iter check_name_of_type (List.map proxy params);
  if is_aliased sty then check_name_of_type (proxy sty);

  let vir_flag = cl.cty_new = None in
  Osig_class
    (vir_flag, Ident.name id,
     List.map2 tree_of_class_param params (class_variance cl.cty_variance),
     tree_of_class_type true params cl.cty_type,
     tree_of_rec rs)

let class_declaration id ppf cl =
  !Oprint.out_sig_item ppf (tree_of_class_declaration id cl Trec_first)

let tree_of_cltype_declaration id cl rs =
  let params = List.map repr cl.clty_params in

  reset ();
  List.iter add_alias params;
  prepare_class_type params cl.clty_type;
  let sty = Ctype.self_type cl.clty_type in
  List.iter mark_loops params;

  List.iter check_name_of_type (List.map proxy params);
  if is_aliased sty then check_name_of_type (proxy sty);

  let sign = Ctype.signature_of_class_type cl.clty_type in

  let virt =
    let (fields, _) =
      Ctype.flatten_fields (Ctype.object_fields sign.csig_self) in
    List.exists
      (fun (lab, _, _) ->
         not (lab = dummy_method || Concr.mem lab sign.csig_concr))
      fields
    || Vars.fold (fun _ (_,vr,_) b -> vr = Virtual || b) sign.csig_vars false
  in

  Osig_class_type
    (virt, Ident.name id,
     List.map2 tree_of_class_param params (class_variance cl.clty_variance),
     tree_of_class_type true params cl.clty_type,
     tree_of_rec rs)

let cltype_declaration id ppf cl =
  !Oprint.out_sig_item ppf (tree_of_cltype_declaration id cl Trec_first)

(* Print a module type *)

let wrap_env fenv ftree arg =
  let env = !printing_env in
  let env' = Env.update_short_paths (fenv env) in
  set_printing_env env';
  let tree = ftree arg in
  set_printing_env env;
  tree

let filter_rem_sig item rem =
  match item, rem with
  | Sig_class _, ctydecl :: tydecl1 :: tydecl2 :: rem ->
      ([ctydecl; tydecl1; tydecl2], rem)
  | Sig_class_type _, tydecl1 :: tydecl2 :: rem ->
      ([tydecl1; tydecl2], rem)
  | _ ->
      ([], rem)

let dummy =
  { type_params = []; type_arity = 0; type_kind = Type_abstract;
    type_private = Public; type_manifest = None; type_variance = [];
    type_is_newtype = false; type_expansion_scope = None;
    type_loc = Location.none;
    type_attributes = [];
    type_immediate = false;
    type_unboxed = unboxed_false_default_false;
  }

let hide_rec_items = function
  | Sig_type(id, _decl, rs) ::rem
    when rs = Trec_first && not !Clflags.real_paths ->
      let rec get_ids = function
          Sig_type (id, _, Trec_next) :: rem ->
            id :: get_ids rem
        | _ -> []
      in
      let ids = id :: get_ids rem in
      let env =
        List.fold_right
          (fun id -> Env.add_type ~check:false (Ident.rename id) dummy)
          ids !printing_env
      in
      let env = Env.update_short_paths env in
      set_printing_env env
  | _ -> ()

let rec tree_of_modtype ?(ellipsis=false) = function
  | Mty_ident p ->
      let p = best_module_type_path p in
      Omty_ident (tree_of_path p)
  | Mty_signature sg ->
      Omty_signature (if ellipsis then [Osig_ellipsis]
                      else tree_of_signature sg)
  | Mty_functor(param, ty_arg, ty_res) ->
      let res =
        match ty_arg with None -> tree_of_modtype ~ellipsis ty_res
        | Some mty ->
            wrap_env (Env.add_module ~arg:true param mty)
                     (tree_of_modtype ~ellipsis) ty_res
      in
      Omty_functor (Ident.name param,
                    may_map (tree_of_modtype ~ellipsis:false) ty_arg, res)
  | Mty_alias(_, p) ->
      let p = best_module_path p in
      Omty_alias (tree_of_path p)

and tree_of_signature sg =
  wrap_env (fun env -> env) (tree_of_signature_rec !printing_env false) sg

and tree_of_signature_rec env' in_type_group = function
    [] -> []
  | item :: rem as items ->
      let env', in_type_group =
        match in_type_group, item with
          true, Sig_type (_, _, Trec_next) -> env', true
        | _, Sig_type (_, _, (Trec_not | Trec_first)) ->
          let env' = Env.update_short_paths env' in
          set_printing_env env';
          env', true
        | _ ->
          let env' = Env.update_short_paths env' in
          set_printing_env env';
          env', false
      in
      let (sg, rem) = filter_rem_sig item rem in
      hide_rec_items items;
      let trees = trees_of_sigitem item in
      let env' = Env.add_signature (item :: sg) env' in
      trees @ tree_of_signature_rec env' in_type_group rem

and trees_of_sigitem = function
  | Sig_value(id, decl) ->
      [tree_of_value_description id decl]
  | Sig_type(id, _, _) when is_row_name (Ident.name id) ->
      []
  | Sig_type(id, decl, rs) ->
      [tree_of_type_declaration id decl rs]
  | Sig_typext(id, ext, es) ->
      [tree_of_extension_constructor id ext es]
  | Sig_module(id, md, rs) ->
      let ellipsis =
        List.exists (function ({txt="..."}, Parsetree.PStr []) -> true
                            | _ -> false)
          md.md_attributes in
      [tree_of_module id md.md_type rs ~ellipsis]
  | Sig_modtype(id, decl) ->
      [tree_of_modtype_declaration id decl]
  | Sig_class(id, decl, rs) ->
      [tree_of_class_declaration id decl rs]
  | Sig_class_type(id, decl, rs) ->
      [tree_of_cltype_declaration id decl rs]

and tree_of_modtype_declaration id decl =
  let mty =
    match decl.mtd_type with
    | None -> Omty_abstract
    | Some mty -> tree_of_modtype mty
  in
  Osig_modtype (Ident.name id, mty)

and tree_of_module id ?ellipsis mty rs =
  Osig_module (Ident.name id, tree_of_modtype ?ellipsis mty, tree_of_rec rs)

let modtype ppf mty = !Oprint.out_module_type ppf (tree_of_modtype mty)
let modtype_declaration id ppf decl =
  !Oprint.out_sig_item ppf (tree_of_modtype_declaration id decl)

(* For the toplevel: merge with tree_of_signature? *)

let rec print_items showval env = function
  | [] -> []
  | item :: rem as items ->
      let (_sg, rem) = filter_rem_sig item rem in
      hide_rec_items items;
      let trees = trees_of_sigitem item in
      List.map (fun d -> (d, showval env item)) trees @
      print_items showval env rem

(* Print a signature body (used by -i when compiling a .ml) *)

let print_signature ppf tree =
  fprintf ppf "@[<v>%a@]" !Oprint.out_signature tree

let signature ppf sg =
  fprintf ppf "%a" print_signature (tree_of_signature sg)

(* Print an unification error *)

let same_path t t' =
  let t = repr t and t' = repr t' in
  t == t' ||
  match t.desc, t'.desc with
  | Tconstr(p,tl,_), Tconstr(p',tl',_) -> begin
      match best_type_path p, best_type_path p' with
      | Nth n, Nth n' when n = n' -> true
      | Path(nso, p), Path(nso', p') when Path.same p p' ->
          let tl = apply_subst_opt nso tl in
          let tl' = apply_subst_opt nso' tl' in
          List.length tl = List.length tl' &&
          List.for_all2 same_type tl tl'
      | _ -> false
      end
  | _ ->
      false

let type_expansion t ppf t' =
  if same_path t t'
  then begin add_delayed (proxy t); type_expr ppf t end
  else
  let t' = if proxy t == proxy t' then unalias t' else t' in
  type_expansion ppf t t'

let type_path_expansion tp ppf tp' =
  if Path.same tp tp' then path ppf tp else
  fprintf ppf "@[<2>%a@ =@ %a@]" path tp path tp'

let rec trace fst txt ppf = function
  | (t1, t1') :: (t2, t2') :: rem ->
      if not fst then fprintf ppf "@,";
      fprintf ppf "@[Type@;<1 2>%a@ %s@;<1 2>%a@] %a"
       (type_expansion t1) t1' txt (type_expansion t2) t2'
       (trace false txt) rem
  | _ -> ()

let rec filter_trace keep_last = function
  | (_, t1') :: (_, t2') :: [] when is_Tvar t1' || is_Tvar t2' ->
      []
  | (t1, t1') :: (t2, t2') :: rem ->
      let rem' = filter_trace keep_last rem in
      if is_constr_row ~allow_ident:true t1'
      || is_constr_row ~allow_ident:true t2'
      || same_path t1 t1' && same_path t2 t2' && not (keep_last && rem' = [])
      then rem'
      else (t1, t1') :: (t2, t2') :: rem'
  | _ -> []

let rec type_path_list ppf = function
  | [tp, tp'] -> type_path_expansion tp ppf tp'
  | (tp, tp') :: rem ->
      fprintf ppf "%a@;<2 0>%a"
        (type_path_expansion tp) tp'
        type_path_list rem
  | [] -> ()

(* Hide variant name and var, to force printing the expanded type *)
let hide_variant_name t =
  match repr t with
  | {desc = Tvariant row} as t when (row_repr row).row_name <> None ->
      newty2 t.level
        (Tvariant {(row_repr row) with row_name = None;
                   row_more = newvar2 (row_more row).level})
  | _ -> t

let prepare_expansion (t, t') =
  let t' = hide_variant_name t' in
  mark_loops t;
  if not (same_path t t') then mark_loops t';
  (t, t')

let may_prepare_expansion compact (t, t') =
  match (repr t').desc with
    Tvariant _ | Tobject _ when compact ->
      mark_loops t; (t, t)
  | _ -> prepare_expansion (t, t')

let print_tags ppf fields =
  match fields with [] -> ()
  | (t, _) :: fields ->
      fprintf ppf "`%s" t;
      List.iter (fun (t, _) -> fprintf ppf ",@ `%s" t) fields

let is_unit env ty =
  match (Ctype.expand_head env ty).desc with
  | Tconstr (p, _, _) -> Path.same p Predef.path_unit
  | _ -> false

let unifiable env ty1 ty2 =
  let snap = Btype.snapshot () in
  let res =
    try Ctype.unify env ty1 ty2; true
    with Unify _ -> false
  in
  Btype.backtrack snap;
  res

let explanation env unif t3 t4 : (Format.formatter -> unit) option =
  match t3.desc, t4.desc with
  | Tarrow (_, ty1, ty2, _), _
    when is_unit env ty1 && unifiable env ty2 t4 ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[Hint: Did you forget to provide `()' as argument?@]")
  | _, Tarrow (_, ty1, ty2, _)
    when is_unit env ty1 && unifiable env t3 ty2 ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[Hint: Did you forget to wrap the expression using `fun () ->'?@]")
  | Ttuple [], Tvar _ | Tvar _, Ttuple [] ->
      Some (fun ppf ->
        fprintf ppf "@,Self type cannot escape its class")
  | Tconstr (p, _, _), Tvar _
    when unif && t4.level < Path.binding_time p ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[The type constructor@;<1 2>%a@ would escape its scope@]"
          path p)
  | Tvar _, Tconstr (p, _, _)
    when unif && t3.level < Path.binding_time p ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[The type constructor@;<1 2>%a@ would escape its scope@]"
          path p)
  | Tvar _, Tunivar _ | Tunivar _, Tvar _ ->
      Some (fun ppf ->
        fprintf ppf "@,The universal variable %a would escape its scope"
          type_expr (if is_Tunivar t3 then t3 else t4))
  | Tvar _, _ | _, Tvar _ ->
      Some (fun ppf ->
        let t, t' = if is_Tvar t3 then (t3, t4) else (t4, t3) in
        if occur_in Env.empty t t' then
          fprintf ppf "@,@[<hov>The type variable %a occurs inside@ %a@]"
            type_expr t type_expr t'
        else
          fprintf ppf "@,@[<hov>This instance of %a is ambiguous:@ %s@]"
            type_expr t'
            "it would escape the scope of its equation")
  | Tfield (lab, _, _, _), _ when lab = dummy_method ->
      Some (fun ppf ->
        fprintf ppf
          "@,Self type cannot be unified with a closed object type")
  | _, Tfield (lab, _, _, _) when lab = dummy_method ->
      Some (fun ppf ->
        fprintf ppf
          "@,Self type cannot be unified with a closed object type")
  | Tfield (l,_,_,{desc=Tnil}), Tfield (l',_,_,{desc=Tnil}) when l = l' ->
      Some (fun ppf ->
        fprintf ppf "@,Types for method %s are incompatible" l)
  | (Tnil|Tconstr _), Tfield (l, _, _, _) ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[The first object type has no method %s@]" l)
  | Tfield (l, _, _, _), (Tnil|Tconstr _) ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[The second object type has no method %s@]" l)
  | Tnil, Tconstr _ | Tconstr _, Tnil ->
      Some (fun ppf ->
        fprintf ppf
          "@,@[The %s object type has an abstract row, it cannot be closed@]"
          (if t4.desc = Tnil then "first" else "second"))
  | Tvariant row1, Tvariant row2 ->
      Some (fun ppf ->
        let row1 = row_repr row1 and row2 = row_repr row2 in
        begin match
          row1.row_fields, row1.row_closed, row2.row_fields, row2.row_closed with
        | [], true, [], true ->
            fprintf ppf "@,These two variant types have no intersection"
        | [], true, (_::_ as fields), _ ->
            fprintf ppf
              "@,@[The first variant type does not allow tag(s)@ @[<hov>%a@]@]"
              print_tags fields
        | (_::_ as fields), _, [], true ->
            fprintf ppf
              "@,@[The second variant type does not allow tag(s)@ @[<hov>%a@]@]"
              print_tags fields
        | [l1,_], true, [l2,_], true when l1 = l2 ->
            fprintf ppf "@,Types for tag `%s are incompatible" l1
        | _ -> ()
        end)
  | _ ->
      None

let rec mismatch env unif = function
    (_, t) :: (_, t') :: rem ->
      begin match mismatch env unif rem with
        Some _ as m -> m
      | None -> explanation env unif t t'
      end
  | [] -> None
  | _ -> assert false

let explain mis ppf =
  match mis with
  | None -> ()
  | Some explain -> explain ppf

let warn_on_missing_def env ppf t =
  match t.desc with
  | Tconstr (p,_,_) ->
    begin
      try
        ignore(Env.find_type p env : Types.type_declaration)
      with Not_found ->
        fprintf ppf
          "@,@[%a is abstract because no corresponding cmi file was found \
           in path.@]" path p
    end
  | _ -> ()

let ident_same_name id1 id2 =
  if Ident.equal id1 id2 && not (Ident.same id1 id2) then begin
    add_unique id1; add_unique id2
  end

let rec path_same_name p1 p2 =
  match p1, p2 with
    Pident id1, Pident id2 -> ident_same_name id1 id2
  | Pdot (p1, s1, _), Pdot (p2, s2, _) when s1 = s2 -> path_same_name p1 p2
  | Papply (p1, p1'), Papply (p2, p2') ->
      path_same_name p1 p2; path_same_name p1' p2'
  | _ -> ()

let type_same_name t1 t2 =
  match (repr t1).desc, (repr t2).desc with
  | Tconstr (p1, _, _), Tconstr (p2, _, _) -> begin
      match best_type_path p1, best_type_path p2 with
      | Path(_, p1), Path(_, p2) ->
          path_same_name p1 p2
      | _, _ -> ()
    end
  | _ -> ()

let rec trace_same_names = function
    (t1, t1') :: (t2, t2') :: rem ->
      type_same_name t1 t2; type_same_name t1' t2'; trace_same_names rem
  | _ -> ()

let unification_error env unif tr txt1 ppf txt2 ty_expect_explanation =
  reset ();
  trace_same_names tr;
  let tr = List.map (fun (t, t') -> (t, hide_variant_name t')) tr in
  let mis = mismatch env unif tr in
  match tr with
  | [] | _ :: [] -> assert false
  | t1 :: t2 :: tr ->
    try
      let tr = filter_trace (mis = None) tr in
      let t1, t1' = may_prepare_expansion (tr = []) t1
      and t2, t2' = may_prepare_expansion (tr = []) t2 in
      print_labels := not !Clflags.classic;
      let tr = List.map prepare_expansion tr in
      fprintf ppf
        "@[<v>\
          @[%t@;<1 2>%a@ \
            %t@;<1 2>%a\
            %t\
          @]%a%t\
         @]"
        txt1 (type_expansion t1) t1'
        txt2 (type_expansion t2) t2'
        ty_expect_explanation
        (trace false "is not compatible with type") tr
        (explain mis);
      if env <> Env.empty
      then begin
        warn_on_missing_def env ppf t1;
        warn_on_missing_def env ppf t2
      end;
      print_labels := true
    with exn ->
      print_labels := true;
      raise exn

let report_unification_error ppf env ?(unif=true) tr
    ?(type_expected_explanation = fun _ -> ())
    txt1 txt2 =
  wrap_printing_env env (fun () -> unification_error env unif tr txt1 ppf txt2
                            type_expected_explanation)
;;

let trace fst keep_last txt ppf tr =
  print_labels := not !Clflags.classic;
  trace_same_names tr;
  try match tr with
    t1 :: t2 :: tr' ->
      if fst then trace fst txt ppf (t1 :: t2 :: filter_trace keep_last tr')
      else trace fst txt ppf (filter_trace keep_last tr);
      print_labels := true
  | _ -> ()
  with exn ->
    print_labels := true;
    raise exn

let report_subtyping_error ppf env tr1 txt1 tr2 =
  wrap_printing_env env (fun () ->
    reset ();
    let tr1 = List.map prepare_expansion tr1
    and tr2 = List.map prepare_expansion tr2 in
    fprintf ppf "@[<v>%a" (trace true (tr2 = []) txt1) tr1;
    if tr2 = [] then fprintf ppf "@]" else
    let mis = mismatch env true tr2 in
    fprintf ppf "%a%t@]"
      (trace false (mis = None) "is not compatible with type") tr2
      (explain mis))

let report_ambiguous_type_error ppf env (tp0, tp0') tpl txt1 txt2 txt3 =
  wrap_printing_env env (fun () ->
    reset ();
    List.iter
      (fun (tp, tp') -> path_same_name tp0 tp; path_same_name tp0' tp')
      tpl;
    match tpl with
      [] -> assert false
    | [tp, tp'] ->
        fprintf ppf
          "@[%t@;<1 2>%a@ \
             %t@;<1 2>%a\
           @]"
          txt1 (type_path_expansion tp) tp'
          txt3 (type_path_expansion tp0) tp0'
    | _ ->
        fprintf ppf
          "@[%t@;<1 2>@[<hv>%a@]\
             @ %t@;<1 2>%a\
           @]"
          txt2 type_path_list tpl
          txt3 (type_path_expansion tp0) tp0')

let shorten_type_path env p =
  wrap_printing_env env
    (fun () -> best_type_path_simple p)

let shorten_module_type_path env p =
  wrap_printing_env env
    (fun () -> best_module_type_path p)

let shorten_module_path env p =
  wrap_printing_env env
    (fun () -> best_module_path p)

let shorten_class_type_path env p =
  wrap_printing_env env
    (fun () -> best_class_type_path_simple p)

let () =
  Env.shorten_module_path := shorten_module_path

let compute_map_for_pers _name = true

