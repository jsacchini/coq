(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* This file contains the syntax-directed part of the type inference
   algorithm introduced by Murthy in Coq V5.10, 1995; the type
   inference algorithm was initially developed in a file named trad.ml
   which formerly contained a simple concrete-to-abstract syntax
   translation function introduced in CoC V4.10 for implementing the
   "exact" tactic, 1989 *)
(* Support for typing term in Ltac environment by David Delahaye, 2000 *)
(* Type inference algorithm made a functor of the coercion and
   pattern-matching compilation by Matthieu Sozeau, March 2006 *)
(* Fixpoint guard index computation by Pierre Letouzey, July 2007 *)

(* Structural maintainer: Hugo Herbelin *)
(* Secondary maintenance: collective *)


open Pp
open Errors
open Util
open Names
open Evd
open Term
open Vars
open Context
open Termops
open Reductionops
open Environ
open Type_errors
open Typeops
open Globnames
open Nameops
open Evarutil
open Pretype_errors
open Glob_term
open Glob_ops
open Evarconv
open Pattern
open Misctypes

type typing_constraint = OfType of types | IsType | WithoutTypeConstraint
type var_map = constr_under_binders Id.Map.t
type unbound_ltac_var_map = Genarg.tlevel Genarg.generic_argument Id.Map.t
type ltac_var_map = var_map * unbound_ltac_var_map
type glob_constr_ltac_closure = ltac_var_map * glob_constr
type pure_open_constr = evar_map * constr

(************************************************************************)
(* This concerns Cases *)
open Inductive
open Inductiveops

(************************************************************************)

(* An auxiliary function for searching for fixpoint guard indexes *)

exception Found of int array

let search_guard loc env possible_indexes fixdefs =
  (* Standard situation with only one possibility for each fix. *)
  (* We treat it separately in order to get proper error msg. *)
  let is_singleton = function [_] -> true | _ -> false in
  if List.for_all is_singleton possible_indexes then
    let indexes = Array.of_list (List.map List.hd possible_indexes) in
    let fix = ((indexes, 0),fixdefs) in
    (try check_fix_if_termination_checking env fix
     with reraise ->
       let e = Errors.push reraise in Loc.raise loc e);
    indexes
  else
    (* we now search recursively amoungst all combinations *)
    (try
       List.iter
	 (fun l ->
	    let indexes = Array.of_list l in
	    let fix = ((indexes, 0),fixdefs) in
	    try check_fix env fix; raise (Found indexes)
	    with TypeError _ -> ())
	 (List.combinations possible_indexes);
       let errmsg = "Cannot guess decreasing argument of fix." in
	 user_err_loc (loc,"search_guard", Pp.str errmsg)
     with Found indexes -> indexes)

(* To embed constr in glob_constr *)
let ((constr_in : constr -> Dyn.t),
     (constr_out : Dyn.t -> constr)) = Dyn.create "constr"

(** Miscellaneous interpretation functions *)

let interp_universe_name evd = function
  | None -> new_univ_level_variable univ_rigid evd
  | Some s ->
    try
      let id = try Id.of_string s with _ -> raise Not_found in
      let names, _ = Universes.global_universe_names () in
	evd, Idmap.find id names
    with Not_found ->
      try let level = Evd.universe_of_name evd s in
	    evd, level
      with Not_found -> 
	new_univ_level_variable ~name:s univ_rigid evd
	
let interp_sort evd = function
  | GProp -> evd, Prop Null
  | GSet -> evd, Prop Pos
  | GType n -> 
    let evd, l = interp_universe_name evd n in
      evd, Type (Univ.Universe.make l)

let interp_elimination_sort = function
  | GProp -> InProp
  | GSet  -> InSet
  | GType _ -> InType

type inference_flags = {
  use_typeclasses : bool;
  use_unif_heuristics : bool;
  use_hook : (env -> evar_map -> evar -> constr) option;
  fail_evar : bool;
  expand_evars : bool
}

let apply_typeclasses env evdref fail_evar =
  evdref := Typeclasses.resolve_typeclasses
     ~filter:(if Flags.is_program_mode () 
	      then Typeclasses.no_goals_or_obligations else Typeclasses.no_goals)
     ~split:true ~fail:fail_evar env !evdref;
  if Flags.is_program_mode () then (* Try optionally solving the obligations *)
    evdref := Typeclasses.resolve_typeclasses
      ~filter:Typeclasses.all_evars ~split:true ~fail:false env !evdref

let apply_inference_hook hook initial_sigma evdref =
  evdref := fold_undefined (fun evk evi sigma ->
    if not (Evd.mem initial_sigma evk) &&
      is_undefined sigma evk (* i.e. not defined by side-effect *)
    then
      try
        let c = hook sigma evk in
        Evd.define evk c sigma
      with Exit ->
        sigma
    else
      sigma) !evdref !evdref

let apply_heuristics env evdref fail_evar =
  (* Resolve eagerly, potentially making wrong choices *)
  try evdref := consider_remaining_unif_problems
	~ts:(Typeclasses.classes_transparent_state ()) env !evdref
  with e when Errors.noncritical e ->
    let e = Errors.push e in if fail_evar then raise e

let check_typeclasses_instances_are_solved env sigma =
  (* Naive way, call resolution again with failure flag *)
  apply_typeclasses env (ref sigma) true

let check_extra_evars_are_solved env initial_sigma sigma =
  Evd.fold_undefined
    (fun evk evi () ->
      if not (Evd.mem initial_sigma evk) then
        let (loc,k) = evar_source evk sigma in
	match k with
	| Evar_kinds.ImplicitArg (gr, (i, id), false) -> ()
	| _ ->
	    let evi = nf_evar_info sigma (Evd.find_undefined sigma evk) in
	    error_unsolvable_implicit loc env sigma evi k None) sigma ()

let check_evars_are_solved env initial_sigma sigma =
  check_typeclasses_instances_are_solved env sigma;
  check_problems_are_solved env sigma;
  check_extra_evars_are_solved env initial_sigma sigma

(* Try typeclasses, hooks, unification heuristics ... *)

let solve_remaining_evars flags env initial_sigma sigma =
  let evdref = ref sigma in
  if flags.use_typeclasses then apply_typeclasses env evdref false;
  if Option.has_some flags.use_hook then
    apply_inference_hook (Option.get flags.use_hook env) initial_sigma evdref;
  if flags.use_unif_heuristics then apply_heuristics env evdref false;
  if flags.fail_evar then check_evars_are_solved env initial_sigma !evdref;
  !evdref

let process_inference_flags flags env initial_sigma (sigma,c) =
  let sigma = solve_remaining_evars flags env initial_sigma sigma in
  let c = if flags.expand_evars then nf_evar sigma c else c in
  sigma,c

(* Allow references to syntaxically inexistent variables (i.e., if applied on an inductive) *)
let allow_anonymous_refs = ref false

(* Utilisé pour inférer le prédicat des Cases *)
(* Semble exagérement fort *)
(* Faudra préférer une unification entre les types de toutes les clauses *)
(* et autoriser des ? à rester dans le résultat de l'unification *)

let evar_type_fixpoint loc env evdref lna lar vdefj =
  let lt = Array.length vdefj in
    if Int.equal (Array.length lar) lt then
      for i = 0 to lt-1 do
        if not (e_cumul env evdref (vdefj.(i)).uj_type
		  (lift lt lar.(i))) then
          error_ill_typed_rec_body_loc loc env !evdref
            i lna vdefj lar
      done

(* coerce to tycon if any *)
let inh_conv_coerce_to_tycon resolve_tc loc env evdref j = function
  | None -> j
  | Some t ->
      evd_comb2 (Coercion.inh_conv_coerce_to resolve_tc loc env) evdref j t

(* used to enforce a name in Lambda when the type constraints itself
   is named, hence possibly dependent *)

let orelse_name name name' = match name with
  | Anonymous -> name'
  | _ -> name

let invert_ltac_bound_name env id0 id =
  try mkRel (pi1 (lookup_rel_id id (rel_context env)))
  with Not_found ->
    errorlabstrm "" (str "Ltac variable " ++ pr_id id0 ++
		       str " depends on pattern variable name " ++ pr_id id ++
		       str " which is not bound in current context.")

let protected_get_type_of env sigma c =
  try Retyping.get_type_of ~lax:true env sigma c
  with Retyping.RetypeError _ ->
    errorlabstrm ""
      (str "Cannot reinterpret " ++ quote (print_constr c) ++
       str " in the current environment.")

let pretype_id loc env evdref (lvar,unbndltacvars) id =
  let sigma = !evdref in
  (* Look for the binder of [id] *)
  try
    let (n,_,typ) = lookup_rel_id id (rel_context env) in
      { uj_val  = mkRel n; uj_type = lift n typ }
  with Not_found ->
    (* Check if [id] is an ltac variable *)
    try
      let (ids,c) = Id.Map.find id lvar in
      let subst = List.map (invert_ltac_bound_name env id) ids in
      let c = substl subst c in
	{ uj_val = c; uj_type = protected_get_type_of env sigma c }
    with Not_found ->
        (* Check if [id] is a ltac variable not bound to a term *)
	(* and build a nice error message *)
      if Id.Map.mem id unbndltacvars then
	user_err_loc (loc,"",
          str "Variable " ++ pr_id id ++ str " should be bound to a term.");
      (* Check if [id] is a section or goal variable *)
      try
	let (_,_,typ) = lookup_named id env in
	(* let _ =  *)
	(*   try  *)
   	(*     let ctx = Decls.variable_context id in *)
	(*       evdref := Evd.merge_context_set univ_rigid !evdref ctx; *)
	(*   with Not_found -> () *)
	(* in *)
	  { uj_val  = mkVar id; uj_type = typ }
      with Not_found ->
	  (* [id] not found, standard error message *)
	  error_var_not_found_loc loc id

let evar_kind_of_term sigma c =
  kind_of_term (whd_evar sigma c)

(*************************************************************************)
(* Main pretyping function                                               *)

let interp_universe_level_name evd = function
  | GProp -> evd, Univ.Level.prop
  | GSet -> evd, Univ.Level.set
  | GType s -> interp_universe_name evd s

let pretype_global loc rigid env evd gr us = 
  let evd, instance = 
    match us with
    | None -> evd, None
    | Some l -> 
      let _, ctx = Universes.unsafe_constr_of_global gr in
      let arr = Univ.Instance.to_array (Univ.UContext.instance ctx) in
      let len = Array.length arr in
	if len != List.length l then
	  user_err_loc (loc, "pretype", 
			str "Universe instance should have length " ++ int len)
	else
	  let evd, l' = List.fold_left (fun (evd, univs) l -> 
	    let evd, l = interp_universe_level_name evd l in
	      (evd, l :: univs)) (evd, []) l
      in 
	evd, Some (Univ.Instance.of_array (Array.of_list (List.rev l')))
  in
    Evd.fresh_global ~rigid ?names:instance env evd gr

let pretype_ref loc evdref env ref us =
  match ref with
  | VarRef id ->
      (* Section variable *)
      (try let (_,_,ty) = lookup_named id env in
   	   (* let ctx = Decls.variable_context id in *)
	   (*   evdref := Evd.merge_context_set univ_rigid !evdref ctx; *)
	     make_judge (mkVar id) ty
       with Not_found ->
         (* This may happen if env is a goal env and section variables have
            been cleared - section variables should be different from goal
            variables *)
         Pretype_errors.error_var_not_found_loc loc id)
  | ref ->
    let evd, c = pretype_global loc univ_flexible env !evdref ref us in
    let () = evdref := evd in
    let ty = Typing.type_of env evd c in
      make_judge c ty

let judge_of_Type evd s =
  let evd, l = interp_universe_name evd s in
  let s = Univ.Universe.make l in
  let judge = 
    { uj_val = mkSort (Type s); uj_type = mkSort (Type (Univ.super s)) }
  in
    evd, judge

let pretype_sort evdref = function
  | GProp -> judge_of_prop
  | GSet -> judge_of_set
  | GType s -> evd_comb1 judge_of_Type evdref s

let new_type_evar evdref env loc =
  let e, s = 
    evd_comb0 (fun evd -> Evarutil.new_type_evar univ_flexible_alg evd env ~src:(loc,Evar_kinds.InternalHole)) evdref
  in e

let get_projection env cst =
  let cb = lookup_constant cst env in
    match cb.Declarations.const_proj with
    | Some {Declarations.proj_ind = mind; proj_npars = n; proj_arg = m; proj_type = ty} -> 
      (cst,mind,n,m,ty)
    | None -> raise Not_found

let (f_genarg_interp, genarg_interp_hook) = Hook.make ()

(* [pretype tycon env evdref lvar lmeta cstr] attempts to type [cstr] *)
(* in environment [env], with existential variables [evdref] and *)
(* the type constraint tycon *)

let is_GHole = function
  | GHole _ -> true
  | _ -> false

let rec pretype resolve_tc (tycon : type_constraint) env evdref lvar t =
  let inh_conv_coerce_to_tycon = inh_conv_coerce_to_tycon resolve_tc in
  let pretype_type = pretype_type resolve_tc in
  let pretype = pretype resolve_tc in
  match t with
  | GRef (loc,ref,u) ->
      inh_conv_coerce_to_tycon loc env evdref
	(pretype_ref loc evdref env ref u)
	tycon

  | GVar (loc, id) ->
    inh_conv_coerce_to_tycon loc env evdref
      (pretype_id loc env evdref lvar id)
      tycon

  | GEvar (loc, evk, instopt) ->
      (* Ne faudrait-il pas s'assurer que hyps est bien un
	 sous-contexte du contexte courant, et qu'il n'y a pas de Rel "caché" *)
      let hyps = evar_filtered_context (Evd.find !evdref evk) in
      let args = match instopt with
        | None -> Array.of_list (instance_from_named_context hyps)
        | Some inst -> failwith "Evar subtitutions not implemented" in
      let c = mkEvar (evk, args) in
      let j = (Retyping.get_judgment_of env !evdref c) in
	inh_conv_coerce_to_tycon loc env evdref j tycon

  | GPatVar (loc,(someta,n)) ->
    let ty =
      match tycon with
      | Some ty -> ty
      | None -> new_type_evar evdref env loc in
    let k = Evar_kinds.MatchingVar (someta,n) in
      { uj_val = e_new_evar evdref env ~src:(loc,k) ty; uj_type = ty }

  | GHole (loc, k, None) ->
      let ty =
        match tycon with
        | Some ty -> ty
        | None ->
          new_type_evar evdref env loc in
        { uj_val = e_new_evar evdref env ~src:(loc,k) ty; uj_type = ty }

  | GHole (loc, k, Some arg) ->
      let ty =
        match tycon with
        | Some ty -> ty
        | None ->
          new_type_evar evdref env loc in
      let ist = snd lvar in
      let (c, sigma) = Hook.get f_genarg_interp ty env !evdref ist arg in
      let () = evdref := sigma in
      { uj_val = c; uj_type = ty }

  | GRec (loc,fixkind,names,bl,lar,vdef) ->
    let rec type_bl env ctxt = function
    [] -> ctxt
      | (na,bk,None,ty)::bl ->
        let ty' = pretype_type empty_valcon env evdref lvar ty in
        let dcl = (na,None,ty'.utj_val) in
	  type_bl (push_rel dcl env) (add_rel_decl dcl ctxt) bl
      | (na,bk,Some bd,ty)::bl ->
        let ty' = pretype_type empty_valcon env evdref lvar ty in
        let bd' = pretype (mk_tycon ty'.utj_val) env evdref lvar bd in
        let dcl = (na,Some bd'.uj_val,ty'.utj_val) in
	  type_bl (push_rel dcl env) (add_rel_decl dcl ctxt) bl in
    let ctxtv = Array.map (type_bl env empty_rel_context) bl in
    let larj =
      Array.map2
        (fun e ar ->
          pretype_type empty_valcon (push_rel_context e env) evdref lvar ar)
        ctxtv lar in
    let lara = Array.map (fun a -> a.utj_val) larj in
    let ftys = Array.map2 (fun e a -> it_mkProd_or_LetIn a e) ctxtv lara in
    let nbfix = Array.length lar in
    let names = Array.map (fun id -> Name id) names in
    let _ = 
      match tycon with
      | Some t -> 
 	let fixi = match fixkind with
	  | GFix (vn,i) -> i
	  | GCoFix i -> i
	in e_conv env evdref ftys.(fixi) t
      | None -> true
    in
      (* Note: bodies are not used by push_rec_types, so [||] is safe *)
    let newenv = push_rec_types (names,ftys,[||]) env in
    let vdefj =
      Array.map2_i
	(fun i ctxt def ->
             (* we lift nbfix times the type in tycon, because of
	      * the nbfix variables pushed to newenv *)
          let (ctxt,ty) =
	    decompose_prod_n_assum (rel_context_length ctxt)
              (lift nbfix ftys.(i)) in
          let nenv = push_rel_context ctxt newenv in
          let j = pretype (mk_tycon ty) nenv evdref lvar def in
	    { uj_val = it_mkLambda_or_LetIn j.uj_val ctxt;
	      uj_type = it_mkProd_or_LetIn j.uj_type ctxt })
        ctxtv vdef in
      evar_type_fixpoint loc env evdref names ftys vdefj;
      let ftys = Array.map (nf_evar !evdref) ftys in
      let fdefs = Array.map (fun x -> nf_evar !evdref (j_val x)) vdefj in
      let fixj = match fixkind with
	| GFix (vn,i) ->
	      (* First, let's find the guard indexes. *)
	      (* If recursive argument was not given by user, we try all args.
	         An earlier approach was to look only for inductive arguments,
		 but doing it properly involves delta-reduction, and it finally
                 doesn't seem worth the effort (except for huge mutual
		 fixpoints ?) *)
	  let possible_indexes =
	    Array.to_list (Array.mapi
			     (fun i (n,_) -> match n with
			     | Some n -> [n]
			     | None -> List.map_i (fun i _ -> i) 0 ctxtv.(i))
			     vn)
	  in
	  let fixdecls = (names,ftys,fdefs) in
	  let indexes =
            search_guard loc env possible_indexes fixdecls in
	    make_judge (mkFix ((indexes,i),fixdecls)) ftys.(i)
	| GCoFix i ->
	  let cofix = (i,(names,ftys,fdefs)) in
	    (try check_cofix env cofix
             with reraise ->
               let e = Errors.push reraise in Loc.raise loc e);
	    make_judge (mkCoFix cofix) ftys.(i)
      in
	inh_conv_coerce_to_tycon loc env evdref fixj tycon

  | GSort (loc,s) ->
    let j = pretype_sort evdref s in
      inh_conv_coerce_to_tycon loc env evdref j tycon

  | GProj (loc, p, arg) ->
    let (cst, mind, n, m, ty) = 
      try get_projection env p 
      with Not_found ->
	user_err_loc (loc,"",str "Not a projection")
    in
    let mk_ty k = 
      let ind = 
	Evarutil.evd_comb1 (Evd.fresh_inductive_instance env) evdref (mind,0)
      in
      let args = 
	let ctx = smash_rel_context (Inductiveops.inductive_params_ctxt ind) in
	  List.fold_right (fun (n, b, ty) (* par  *)args ->
	    let ty = substl args ty in
	    let ev = e_new_evar evdref env ~src:(loc,k) ty in
	      ev :: args) ctx []
      in (ind, List.rev args)
    in
    let argtycon =
      match arg with
      | GHole (loc, k, _) -> (* Typeclass projection application: 
				create the necessary type constraint *)
	let ind, args = mk_ty k in
	  mk_tycon (applist (mkIndU ind, args))
      | _ -> empty_tycon
    in
    let recty = pretype argtycon env evdref lvar arg in
    let recty, ((ind,u), pars) = 
      try
	let IndType (indf, _ (*[]*)) = 
	  find_rectype env !evdref recty.uj_type
	in 
	let ((ind', _), _) as indf = dest_ind_family indf in
	  if not (eq_ind ind' (mind,0)) then raise Not_found
	  else recty, indf
      with Not_found -> 
	(match argtycon with
	| Some ty -> assert false
	| None -> 
	  let ind, args = mk_ty Evar_kinds.InternalHole in
	  let j' = 
	    inh_conv_coerce_to_tycon (loc_of_glob_constr arg) env evdref recty 
	      (mk_tycon (applist (mkIndU ind, args))) in
	    j', (ind, args))
    in
    let usubst = make_inductive_subst (fst (lookup_mind_specif env ind)) u in
    let ty = Vars.subst_univs_level_constr usubst ty in
    let ty = substl (recty.uj_val :: List.rev pars) ty in
    let j = {uj_val = mkProj (cst,recty.uj_val); uj_type = ty} in
      inh_conv_coerce_to_tycon loc env evdref j tycon

  | GApp (loc,f,args) ->
    let fj = pretype empty_tycon env evdref lvar f in
    let floc = loc_of_glob_constr f in
    let length = List.length args in
    let candargs =
	(* Bidirectional typechecking hint: 
	   parameters of a constructor are completely determined
	   by a typing constraint *)
      if Flags.is_program_mode () && length > 0 && isConstruct fj.uj_val then
	match tycon with
	| None -> []
	| Some ty ->
	  let ((ind, i), u) = destConstruct fj.uj_val in
	  let npars = inductive_nparams ind in
	    if Int.equal npars 0 then []
	    else
	      try
	  	let IndType (indf, args) = find_rectype env !evdref ty in
	  	let ((ind',u'),pars) = dest_ind_family indf in
	  	  if eq_ind ind ind' then pars
	  	  else (* Let the usual code throw an error *) []
	      with Not_found -> []
      else []
    in
    let rec apply_rec env n resj candargs = function
      | [] -> resj
      | c::rest ->
	let argloc = loc_of_glob_constr c in
	let resj = evd_comb1 (Coercion.inh_app_fun resolve_tc env) evdref resj in
        let resty = whd_betadeltaiota env !evdref resj.uj_type in
      	  match kind_of_term resty with
	  | Prod (na,c1,c2) ->
	    let tycon = Some c1 in
	    let hj = pretype tycon env evdref lvar c in
	    let candargs, ujval =
	      match candargs with
	      | [] -> [], j_val hj
	      | arg :: args -> 
		if e_conv env evdref (j_val hj) arg then
		  args, nf_evar !evdref (j_val hj)
		else [], j_val hj
	    in
	    let value, typ = applist (j_val resj, [ujval]), subst1 ujval c2 in
	    let j = { uj_val = value; uj_type = typ } in
	      apply_rec env (n+1) j candargs rest
		
	  | _ ->
	    let hj = pretype empty_tycon env evdref lvar c in
	      error_cant_apply_not_functional_loc
		(Loc.merge floc argloc) env !evdref
	      	resj [hj]
    in
    let resj = apply_rec env 1 fj candargs args in
    let resj =
      match evar_kind_of_term !evdref resj.uj_val with
      | App (f,args) ->
        let f = whd_evar !evdref f in
          if isInd f && is_template_polymorphic env f then
	    (* Special case for inductive type applications that must be 
	       refreshed right away. *)
	    let sigma = !evdref in
	    let c = mkApp (f,Array.map (whd_evar sigma) args) in
	    let c = evd_comb1 (Evarsolve.refresh_universes (Some true) env) evdref c in
	    let t = Retyping.get_type_of env !evdref c in
	      make_judge c (* use this for keeping evars: resj.uj_val *) t
	  else resj
      | _ -> resj 
    in
      inh_conv_coerce_to_tycon loc env evdref resj tycon

  | GLambda(loc,name,bk,c1,c2)      ->
    let tycon' = evd_comb1
      (fun evd tycon ->
	match tycon with
	| None -> evd, tycon
	| Some ty ->
	  let evd, ty' = Coercion.inh_coerce_to_prod loc env evd ty in
	    evd, Some ty')
      evdref tycon
    in
    let (name',dom,rng) = evd_comb1 (split_tycon loc env) evdref tycon' in
    let dom_valcon = valcon_of_tycon dom in
    let j = pretype_type dom_valcon env evdref lvar c1 in
    let var = (name,None,j.utj_val) in
    let j' = pretype rng (push_rel var env) evdref lvar c2 in
    let resj = judge_of_abstraction env (orelse_name name name') j j' in
      inh_conv_coerce_to_tycon loc env evdref resj tycon

  | GProd(loc,name,bk,c1,c2)        ->
    let j = pretype_type empty_valcon env evdref lvar c1 in
    let j' = match name with
      | Anonymous ->
        let j = pretype_type empty_valcon env evdref lvar c2 in
          { j with utj_val = lift 1 j.utj_val }
      | Name _ ->
        let var = (name,j.utj_val) in
        let env' = push_rel_assum var env in
          pretype_type empty_valcon env' evdref lvar c2
    in
    let resj =
      try judge_of_product env name j j'
      with TypeError _ as e -> let e = Errors.push e in Loc.raise loc e in
      inh_conv_coerce_to_tycon loc env evdref resj tycon

  | GLetIn(loc,name,c1,c2)      ->
    let j =
      match c1 with
      | GCast (loc, c, CastConv t) ->
	let tj = pretype_type empty_valcon env evdref lvar t in
	  pretype (mk_tycon tj.utj_val) env evdref lvar c
      | _ -> pretype empty_tycon env evdref lvar c1
    in
    let t = j.uj_type in
    let var = (name,Some j.uj_val,t) in
    let tycon = lift_tycon 1 tycon in
    let j' = pretype tycon (push_rel var env) evdref lvar c2 in
      { uj_val = mkLetIn (name, j.uj_val, t, j'.uj_val) ;
	uj_type = subst1 j.uj_val j'.uj_type }

  | GLetTuple (loc,nal,(na,po),c,d) ->
    let cj = pretype empty_tycon env evdref lvar c in
    let (IndType (indf,realargs)) =
      try find_rectype env !evdref cj.uj_type
      with Not_found ->
	let cloc = loc_of_glob_constr c in
	  error_case_not_inductive_loc cloc env !evdref cj
    in
    let cstrs = get_constructors env indf in
      if not (Int.equal (Array.length cstrs) 1) then
        user_err_loc (loc,"",str "Destructing let is only for inductive types" ++
	  str " with one constructor.");
      let cs = cstrs.(0) in
	if not (Int.equal (List.length nal) cs.cs_nargs) then
          user_err_loc (loc,"", str "Destructing let on this type expects " ++ 
	    int cs.cs_nargs ++ str " variables.");
	let fsign = List.map2 (fun na (_,c,t) -> (na,c,t))
          (List.rev nal) cs.cs_args in
	let env_f = push_rel_context fsign env in
	  (* Make dependencies from arity signature impossible *)
	let arsgn =
	  let arsgn,_ = get_arity env indf in
	    if not !allow_anonymous_refs then
	      List.map (fun (_,b,t) -> (Anonymous,b,t)) arsgn
	    else arsgn
	in
	let psign = (na,None,build_dependent_inductive env indf)::arsgn in
	let nar = List.length arsgn in
	  (match po with
	  | Some p ->
	    let env_p = push_rel_context psign env in
	    let pj = pretype_type empty_valcon env_p evdref lvar p in
	    let ccl = nf_evar !evdref pj.utj_val in
	    let psign = make_arity_signature env true indf in (* with names *)
	    let p = it_mkLambda_or_LetIn ccl psign in
	    let inst =
	      (Array.to_list cs.cs_concl_realargs)
	      @[build_dependent_constructor cs] in
	    let lp = lift cs.cs_nargs p in
	    let fty = hnf_lam_applist env !evdref lp inst in
	    let fj = pretype (mk_tycon fty) env_f evdref lvar d in
	    let f = it_mkLambda_or_LetIn fj.uj_val fsign in
	    let v =
	      let ind,_ = dest_ind_family indf in
	      let ci = make_case_info env (fst ind) LetStyle in
		Typing.check_allowed_sort env !evdref ind cj.uj_val p;
		mkCase (ci, p, cj.uj_val,[|f|]) in
	      { uj_val = v; uj_type = substl (realargs@[cj.uj_val]) ccl }

	  | None ->
	    let tycon = lift_tycon cs.cs_nargs tycon in
	    let fj = pretype tycon env_f evdref lvar d in
	    let f = it_mkLambda_or_LetIn fj.uj_val fsign in
	    let ccl = nf_evar !evdref fj.uj_type in
	    let ccl =
	      if noccur_between 1 cs.cs_nargs ccl then
		lift (- cs.cs_nargs) ccl
	      else
		error_cant_find_case_type_loc loc env !evdref
		  cj.uj_val in
		 (* let ccl = refresh_universes ccl in *)
	    let p = it_mkLambda_or_LetIn (lift (nar+1) ccl) psign in
	    let v =
	      let ind,_ = dest_ind_family indf in
	      let ci = make_case_info env (fst ind) LetStyle in
		Typing.check_allowed_sort env !evdref ind cj.uj_val p;
		mkCase (ci, p, cj.uj_val,[|f|])
	    in { uj_val = v; uj_type = ccl })

  | GIf (loc,c,(na,po),b1,b2) ->
    let cj = pretype empty_tycon env evdref lvar c in
    let (IndType (indf,realargs)) =
      try find_rectype env !evdref cj.uj_type
      with Not_found ->
	let cloc = loc_of_glob_constr c in
	  error_case_not_inductive_loc cloc env !evdref cj in
    let cstrs = get_constructors env indf in
      if not (Int.equal (Array.length cstrs) 2) then
        user_err_loc (loc,"",
		      str "If is only for inductive types with two constructors.");

      let arsgn =
	let arsgn,_ = get_arity env indf in
	  if not !allow_anonymous_refs then
	      (* Make dependencies from arity signature impossible *)
	    List.map (fun (_,b,t) -> (Anonymous,b,t)) arsgn
	  else arsgn
      in
      let nar = List.length arsgn in
      let psign = (na,None,build_dependent_inductive env indf)::arsgn in
      let pred,p = match po with
	| Some p ->
	  let env_p = push_rel_context psign env in
	  let pj = pretype_type empty_valcon env_p evdref lvar p in
	  let ccl = nf_evar !evdref pj.utj_val in
	  let pred = it_mkLambda_or_LetIn ccl psign in
	  let typ = lift (- nar) (beta_applist (pred,[cj.uj_val])) in
	    pred, typ
	| None ->
	  let p = match tycon with
	    | Some ty -> ty
	    | None -> new_type_evar evdref env loc
	  in
	    it_mkLambda_or_LetIn (lift (nar+1) p) psign, p in
      let pred = nf_evar !evdref pred in
      let p = nf_evar !evdref p in
      let f cs b =
	let n = rel_context_length cs.cs_args in
	let pi = lift n pred in (* liftn n 2 pred ? *)
	let pi = beta_applist (pi, [build_dependent_constructor cs]) in
	let csgn =
	  if not !allow_anonymous_refs then
	    List.map (fun (_,b,t) -> (Anonymous,b,t)) cs.cs_args
	  else
	    List.map
	      (fun (n, b, t) ->
		match n with
                  Name _ -> (n, b, t)
                | Anonymous -> (Name Namegen.default_non_dependent_ident, b, t))
	      cs.cs_args
	in
	let env_c = push_rel_context csgn env in
	let bj = pretype (mk_tycon pi) env_c evdref lvar b in
	  it_mkLambda_or_LetIn bj.uj_val cs.cs_args in
      let b1 = f cstrs.(0) b1 in
      let b2 = f cstrs.(1) b2 in
      let v =
	let ind,_ = dest_ind_family indf in
	let ci = make_case_info env (fst ind) IfStyle in
	let pred = nf_evar !evdref pred in
	  Typing.check_allowed_sort env !evdref ind cj.uj_val pred;
	  mkCase (ci, pred, cj.uj_val, [|b1;b2|])
      in
	{ uj_val = v; uj_type = p }

  | GCases (loc,sty,po,tml,eqns) ->
    Cases.compile_cases loc sty
      ((fun vtyc env evdref -> pretype vtyc env evdref lvar),evdref)
      tycon env (* loc *) (po,tml,eqns)

  | GCast (loc,c,k) ->
    let cj =
      match k with
      | CastCoerce ->
	let cj = pretype empty_tycon env evdref lvar c in
	  evd_comb1 (Coercion.inh_coerce_to_base loc env) evdref cj
      | CastConv t | CastVM t | CastNative t ->
	let k = (match k with CastVM _ -> VMcast | CastNative _ -> NATIVEcast | _ -> DEFAULTcast) in
	let tj = pretype_type empty_valcon env evdref lvar t in
	let tval = nf_evar !evdref tj.utj_val in
	let cj = match k with
	  | VMcast ->
 	    let cj = pretype empty_tycon env evdref lvar c in
	    let cty = nf_evar !evdref cj.uj_type and tval = nf_evar !evdref tj.utj_val in
	      if not (occur_existential cty || occur_existential tval) then
		begin 
		  try 
		    ignore (Reduction.vm_conv Reduction.CUMUL env cty tval); cj
		  with Reduction.NotConvertible -> 
		    error_actual_type_loc loc env !evdref cj tval 
                      (ConversionFailed (env,cty,tval))
		end
	      else user_err_loc (loc,"",str "Cannot check cast with vm: " ++
		str "unresolved arguments remain.")
	  | NATIVEcast ->
 	    let cj = pretype empty_tycon env evdref lvar c in
	    let cty = nf_evar !evdref cj.uj_type and tval = nf_evar !evdref tj.utj_val in
            let evars = Nativenorm.evars_of_evar_map !evdref in
            begin
              try
                ignore (Nativeconv.native_conv Reduction.CUMUL evars env cty tval); cj
              with Reduction.NotConvertible -> 
                error_actual_type_loc loc env !evdref cj tval 
                  (ConversionFailed (env,cty,tval))
            end
	  | _ -> 
 	    pretype (mk_tycon tval) env evdref lvar c
	in
	let v = mkCast (cj.uj_val, k, tval) in
	  { uj_val = v; uj_type = tval }
    in inh_conv_coerce_to_tycon loc env evdref cj tycon

(* [pretype_type valcon env evdref lvar c] coerces [c] into a type *)
and pretype_type resolve_tc valcon env evdref lvar = function
  | GHole (loc, knd, None) ->
      (match valcon with
       | Some v ->
           let s =
	     let sigma =  !evdref in
	     let t = Retyping.get_type_of env sigma v in
	       match kind_of_term (whd_betadeltaiota env sigma t) with
               | Sort s -> s
               | Evar ev when is_Type (existential_type sigma ev) ->
		   evd_comb1 (define_evar_as_sort) evdref ev
               | _ -> anomaly (Pp.str "Found a type constraint which is not a type")
           in
	     { utj_val = v;
	       utj_type = s }
       | None ->
	   let s = evd_comb0 (new_sort_variable univ_flexible_alg) evdref in
	     { utj_val = e_new_evar evdref env ~src:(loc, knd) (mkSort s);
	       utj_type = s})
  | c ->
      let j = pretype resolve_tc empty_tycon env evdref lvar c in
      let loc = loc_of_glob_constr c in
      let tj = evd_comb1 (Coercion.inh_coerce_to_sort loc env) evdref j in
	match valcon with
	| None -> tj
	| Some v ->
	    if e_cumul env evdref v tj.utj_val then tj
	    else
	      error_unexpected_type_loc
                (loc_of_glob_constr c) env !evdref tj.utj_val v

let ise_pretype_gen flags sigma env lvar kind c =
  let evdref = ref sigma in
  let c' = match kind with
    | WithoutTypeConstraint ->
        (pretype flags.use_typeclasses empty_tycon env evdref lvar c).uj_val
    | OfType exptyp ->
	(pretype flags.use_typeclasses (mk_tycon exptyp) env evdref lvar c).uj_val
    | IsType ->
	(pretype_type flags.use_typeclasses empty_valcon env evdref lvar c).utj_val 
  in
  process_inference_flags flags env sigma (!evdref,c')

let default_inference_flags fail = {
  use_typeclasses = true;
  use_unif_heuristics = true;
  use_hook = None;
  fail_evar = fail;
  expand_evars = true }

let no_classes_no_fail_inference_flags = {
  use_typeclasses = false;
  use_unif_heuristics = true;
  use_hook = None;
  fail_evar = false;
  expand_evars = true }

let all_and_fail_flags = default_inference_flags true
let all_no_fail_flags = default_inference_flags false

let empty_lvar : ltac_var_map = (Id.Map.empty, Id.Map.empty)

let on_judgment f j =
  let c = mkCast(j.uj_val,DEFAULTcast, j.uj_type) in
  let (c,_,t) = destCast (f c) in
  {uj_val = c; uj_type = t}

let understand_judgment sigma env c =
  let evdref = ref sigma in
  let j = pretype true empty_tycon env evdref empty_lvar c in
  let j = on_judgment (fun c ->
    let evd, c = process_inference_flags all_and_fail_flags env sigma (!evdref,c) in 
      evdref := evd; c) j
  in j, Evd.evar_universe_context !evdref

let understand_judgment_tcc evdref env c =
  let j = pretype true empty_tycon env evdref empty_lvar c in
  on_judgment (fun c ->
    let (evd,c) = process_inference_flags all_no_fail_flags env Evd.empty (!evdref,c) in
    evdref := evd; c) j

let ise_pretype_gen_ctx flags sigma env lvar kind c =
  let evd, c = ise_pretype_gen flags sigma env lvar kind c in
  let evd, f = Evarutil.nf_evars_and_universes evd in
    f c, Evd.evar_universe_context evd

(** Entry points of the high-level type synthesis algorithm *)

let understand
    ?(flags=all_and_fail_flags)
    ?(expected_type=WithoutTypeConstraint)
    sigma env c =
  ise_pretype_gen_ctx flags sigma env empty_lvar expected_type c

let understand_tcc ?(flags=all_no_fail_flags) sigma env ?(expected_type=WithoutTypeConstraint) c =
  ise_pretype_gen flags sigma env empty_lvar expected_type c

let understand_tcc_evars ?(flags=all_no_fail_flags) evdref env ?(expected_type=WithoutTypeConstraint) c =
  let sigma, c = ise_pretype_gen flags !evdref env empty_lvar expected_type c in
  evdref := sigma;
  c

let understand_ltac flags sigma env lvar kind c =
  ise_pretype_gen flags sigma env lvar kind c
