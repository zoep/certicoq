(* Generic beta-contraction phase for (stateful) heuristics based on function definitions and call sites, with bounded inlining depth
   *)
Require Import Common.compM Common.Pipeline_utils L6.cps.
Require Import Coq.ZArith.ZArith Coq.Lists.List Coq.Strings.String.
Import ListNotations.
Require Import identifiers.
Require Import L6.state L6.cps_util L6.cps_show L6.ctx L6.uncurry L6.shrink_cps L6.rename L6.inline_letapp.
Require Import ExtLib.Structures.Monad.
Require Import ExtLib.Structures.MonadState.
Require Import ExtLib.Data.Monads.StateMonad.
Require Coq.Program.Wf.
Require Import Program.
(* Require Import Template.monad_utils. *)
Require Import Coq.Structures.OrdersEx.

Import MonadNotation.
Open Scope monad_scope.

Definition r_map := M.t var.

(* St is the type of the [scoped] state used by the  heuristic *)
Record InlineHeuristic (St:Type) :=
  { update_funDef:(fundefs -> r_map -> St -> (St * St)); (* update inlining decision at functions declaraction. First state is used for the body of the program, second for the function definitions *)
    update_inFun:(var -> fun_tag -> list var -> exp -> r_map -> St -> St); (* update inlining decisions when converting a function within a bundle *)
    update_App:(var -> fun_tag -> list var -> St -> (St*bool)); (* update and return inlining decision for f on function application *)
    update_letApp:(var -> fun_tag -> list var -> St -> (St * bool)) (* update and return inlining decision for f on let bound function application *)
  }.

Definition fun_map := M.t (fun_tag * list var * exp).

Definition inlineM : Type -> Type := @compM' unit.

Section Beta.

  Variable St:Type.
  (* Pretty print the state for debugging purposes *)
  Variable (pp_St : St -> name_env -> string). 
  Variable IH : InlineHeuristic St.

  (* Construct known-functions map *)
  Fixpoint add_fundefs (fds:fundefs) (fm: fun_map) : fun_map :=
    match fds with
    | Fnil => fm
    | Fcons f t xs e fds => M.set f (t, xs, e) (add_fundefs fds fm)
    end.

  Instance OptMonad : Monad option.
  Proof.
    constructor.
    - intros X x. exact (Some x).
    - intros A B [ a | ] f.
      now eauto.
      exact None.
  Defined.

  Definition debug_st (s : St) : inlineM unit :=
    nenv <- get_name_env () ;;
    log_msg (pp_St s nenv);;
    log_msg Pipeline_utils.newline.

  Definition split_fuel d : nat * nat :=
    let d2 := Nat.div2 d in
    (d2, d2 + Nat.b2n (Nat.odd d)).

  Lemma split_fuel_add d :
    d = fst (split_fuel d) + snd (split_fuel d). 
  Proof.
    unfold split_fuel. simpl. rewrite (NPeano.Nat.div2_odd d) at 1. simpl.    
    omega.
  Qed.
    
  
  Program Fixpoint beta_contract (d : nat) {measure d} :=
    let fix beta_contract_aux (e : exp) (sig : r_map) (fm:fun_map) (s:St) (str_flag : bool) {struct e} : inlineM exp :=
        match e with
        | Econstr x t ys e =>
          let ys' := apply_r_list sig ys in
          x' <- get_name x "" ;;
          e' <- beta_contract_aux e (M.set x x' sig) fm s str_flag ;;
          ret (Econstr x' t ys' e')
        | Ecase v cl =>
          let v' := apply_r sig v in
          cl' <- (fix beta_list (br: list (ctor_tag*exp)) : inlineM (list (ctor_tag*exp)) :=
                   match br with
                   | nil => ret ( nil)
                   | (t, e)::br' =>
                     e' <- beta_contract_aux e sig fm s str_flag ;;
                     br'' <- beta_list br';;
                     ret ((t, e')::br'')
                   end) cl;;
          ret (Ecase v' cl')
       | Eproj x t n y e =>
         let y' := apply_r sig y in
         x' <- get_name x "" ;;
         e' <- beta_contract_aux e (M.set x x' sig) fm s str_flag ;;
         ret (Eproj x' t n y' e')
       | Eletapp x f t ys ec =>         
         let f' := apply_r sig f in
         let ys' := apply_r_list sig ys in
         let (s' , inl) := update_letApp _ IH f t ys' s in
         fstr <- get_pp_name f' ;;
         (* log_msg ("Application of " ++ fstr ++ " is " ++ (if inl then "" else "not ") ++ "inlined") ;; *)
         (match (inl, M.get f fm, d) with
          | (true, Some  (ft, xs, e), S d') =>
            if (Nat.eqb (List.length xs) (List.length ys)) then 
              let sig' := set_list (combine xs ys') sig  in
              x' <- get_name x "" ;;
              let '(d1, d2) := split_fuel d' in
              e' <- beta_contract d1 e sig' (M.remove f fm) s' str_flag ;;
              match inline_letapp e' x', Nat.eqb (List.length xs) (List.length ys) with
              | Some (C, x'), true =>
                ec' <- beta_contract d2 ec (M.set x x' sig) fm s' str_flag ;;
                ret (C |[ ec' ]|)
              | _, _ =>
                x' <- get_name x "" ;;
                ec' <- beta_contract_aux ec (M.set x x' sig) fm s' str_flag ;;
                ret (Eletapp x' f' t ys' ec')
              end
            else
              x' <- get_name x "" ;;
              ec' <- beta_contract_aux ec (M.set x x' sig) fm s' str_flag ;;
              ret (Eletapp x' f' t ys' ec')
          | _ =>
            x' <- get_name x "" ;;
            ec' <- beta_contract_aux ec (M.set x x' sig) fm s' str_flag;;
            ret (Eletapp x' f' t ys' ec')
          end)
       | Efun fds e =>
         let fm' := add_fundefs fds fm in
         let (s1, s2) := update_funDef _ IH fds sig s in
         let names := all_fun_name fds in
         names' <- get_names_lst names "" ;;
         let sig' := set_list (combine names names') sig in
         fds' <- (fix beta_contract_fds (fds:fundefs) (s:St) : inlineM fundefs :=
                   match fds with
                   | Fcons f t xs e fds' =>
                     let s' := update_inFun _ IH f t xs e sig s in
                     let f' := apply_r sig' f in
                     xs' <- get_names_lst xs "" ;;
                     e' <- beta_contract_aux e (set_list (combine xs xs') sig') fm' s' false ;;
                     fds'' <- beta_contract_fds fds' s ;;
                     ret (Fcons f' t xs' e' fds'')
                   | Fnil => ret Fnil
                   end) fds s2 ;;
         e' <- beta_contract_aux e sig' fm' s1 str_flag;;
         ret (Efun fds' e')
       | Eapp f t ys =>
         let f' := apply_r sig f in
         let ys' := apply_r_list sig ys in
         let (s', inl) := update_App _ IH f t ys' s in
         fstr <- get_pp_name f' ;;
         (* log_msg ("Application of " ++ fstr ++ " is " ++ (if inl then "" else "not ") ++ "inlined") ;; *)
         (match (inl, M.get f fm, d) with
          | (true, Some (ft, xs, e), S d') =>
            if (Nat.eqb (List.length xs) (List.length ys) && (negb str_flag || straight_code e))%bool then
              let sig' := set_list (combine xs ys') sig  in
              beta_contract d' e sig' (M.remove f fm) s' str_flag
            else
              ret (Eapp f' t ys')
          | _ =>
            ret (Eapp f' t ys')
          end)
       | Eprim x t ys e =>
         let ys' := apply_r_list sig ys in
         x' <- get_name x "" ;;
         e' <- beta_contract_aux e (M.set x x' sig) fm s str_flag ;;
         ret (Eprim x' t ys' e')
       | Ehalt x =>
         let x' := apply_r sig x in
         ret (Ehalt x')
        end
    in beta_contract_aux.

  Next Obligation.
    eapply le_trans. reflexivity. eapply le_n_S. 
    eapply NPeano.Nat.div2_decr. omega.
  Qed.
  Next Obligation.
    destruct d'. simpl. omega.
    replace (S (S d')) with (S d' + 1) by omega. 
    eapply plus_lt_le_compat.
    eapply NPeano.Nat.lt_div2. omega. 
    
    destruct ((Nat.odd (S d'))); simpl; omega.
  Qed.
    
  Definition beta_contract_top (e:exp) (d:nat) (s:St) (c:comp_data) (str_flag: bool) : error exp * comp_data :=
    let '(e', (st', _)) := run_compM (beta_contract d e (M.empty var) (M.empty _) s str_flag) c tt in
    (e', st').

End Beta.

(** * Encoding of inline heauristics *)
(* Currently supported heuristics:
   1. Inline uncurry shells
      - By inlinning marked functions from uncurry, OR
      - By looking for the pattern of uncurry shell
   2. Inline small functions
 *)


Definition CombineInlineHeuristic {St1 St2:Type} (deci:bool -> bool -> bool)
           (IH1:InlineHeuristic St1) (IH2:InlineHeuristic St2) : InlineHeuristic (prod St1 St2) :=
  {| update_funDef :=
       fun fds sigma (s:(prod St1 St2)) =>
         let (s1, s2) := s in
         let (s11, s12) := update_funDef _ IH1 fds sigma s1 in
         let (s21, s22) := update_funDef _ IH2 fds sigma s2 in
         ((s11, s21) , (s12, s22));
     update_inFun  :=
       fun (f:var) (t:fun_tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) =>
         let (s1, s2) := s in
         let s1' := update_inFun _ IH1 f t xs e sigma s1 in
         let s2' := update_inFun _ IH2 f t xs e sigma s2 in
         (s1', s2');
     update_App  :=
       fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
         let (s1, s2) := s in
         let (s1', b1) := update_App _ IH1 f t ys s1 in
         let (s2', b2) := update_App _ IH2 f t ys s2 in
         ((s1', s2'), deci b1 b2 );
     update_letApp  :=
       fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
         let (s1, s2) := s in
         let (s1', b1) := update_letApp _ IH1 f t ys s1 in
         let (s2', b2) := update_letApp _ IH2 f t ys s2 in
         ((s1', s2'), deci b1 b2 )|}.


Definition InlineSmallIH (bound:nat): InlineHeuristic (M.t bool) :=
  {| (* Inline small functions, but not inside their body (alternatively, check if they are recursive) *)
    update_funDef  := (fun (fds:fundefs) (sigma:r_map) (s:_) =>
                         let s' :=
                             (fix upd (fds:fundefs) (sigma:r_map) (s:_) :=
                                match fds with
                                | Fcons f t xs e fdc' => if (Init.Nat.ltb (term_size e) bound) then
                                                          upd fdc' sigma (M.set f true s)
                                                        else  upd fdc' sigma s
                                | Fnil => s
                                end) fds sigma s in (s', s'));
    update_inFun := fun (f:var) (t:fun_tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) => (M.remove f s);
    update_App := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                    match M.get f s with
                    | Some true => (M.remove f s, true)
                    | _ => (s, false)
                    end;
    update_letApp := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                       match M.get f s with
                       | Some true => (M.remove f s, true)
                       | _ => (s, false)
                       end;
  |}.

Open Scope positive.

Definition InlinedUncurriedMarked : InlineHeuristic (M.t nat) :=  
  {| update_funDef := fun (fds:fundefs) (sigma:r_map) (s:_) => (s, s);
     update_inFun := fun (f:var) (t:fun_tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) => s;
     update_App := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                    match M.get f s with
                    | Some 1%nat => (s, true)
                    | Some 2%nat => (s, true)
                    | _ => (s, false)
                    end;
     update_letApp :=
       fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
         match M.get f s with
         | Some 1%nat => (s, true)
         | Some 2%nat => (s, true)
         | _ => (s, false)
         end;

  |}.


Fixpoint find_uncurried (fds : fundefs) (s:M.t bool) : M.t bool :=
  match fds with
  | Fcons f t (k::xs) (Efun (Fcons h _ _ _ Fnil) (Eapp k' _ [h'])) fds' =>
    let s' := M.set f true s in
        (* if andb (h =? h') (k =? k') then M.set f true s else s in *)
    find_uncurried fds' s'
  | _ => s
  end.

Definition InineUncurriedPats: InlineHeuristic (M.t bool) :=
  {| update_funDef  := (fun (fds:fundefs) (sigma:r_map) (s:_) =>
                          let s' := find_uncurried fds s in
                          (s', s'));
     update_inFun := fun (f:var) (t:fun_tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) => (M.remove f s);
     update_App := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                     match M.get f s with
                     | Some true => (s, true)
                     | _ => (s, false)
                     end;
     update_letApp := fun (f:var) (t:fun_tag) (ys:list var) (s:_) => (s, false)
  |}.


Fixpoint find_uncurried_pats_anf (fds : fundefs) (s:M.t bool) : M.t bool :=
  match fds with
  | Fcons f t xs (Efun (Fcons h ht ys e Fnil) (Ehalt h')) fds' =>
    let s' := if ((h =? h') && negb (occurs_in_exp f (Efun (Fcons h ht ys e Fnil) (Ehalt h'))))%bool then M.set f true s else s in
    find_uncurried fds' s'
  | Fcons f t xs (Eapp f' t' xs') fds' =>
    let s' := if (occurs_in_exp f (Eapp f' t' xs')) then s else M.set f true s in
    find_uncurried fds' s'
  | _ => s
  end.


(* Inlines functions based on patterns found in the code *)
Definition InineUncurriedPatsAnf : InlineHeuristic (M.t bool) :=
  {| update_funDef  := (fun (fds:fundefs) (sigma:r_map) (s:_) =>
                          let s' := find_uncurried_pats_anf fds s in
                          (s', s'));
     update_inFun := fun (f:var) (t:fun_tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) => (M.remove f s);
     update_App := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                     match M.get f s with
                     | Some true => (s, true)
                     | _ => (s, false)
                     end;
     update_letApp := fun (f:var) (t:fun_tag) (ys:list var) (s:_) =>
                        match M.get f s with
                        | Some true => (s, true)
                        | _ => (s, false)
                        end;
  |}.


(* DEBUGGING *)
Definition show_map {A} (m : M.t A) (nenv : name_env) (str : A -> string) :=
  (let fix show_lst (lst : list (var * A)) :=
      match lst with
      | (x, a) :: lst =>
        (show_tree (show_var nenv x)) ++ " -> " ++ str a ++ "; " ++ show_lst lst
      | [] => ""
      end
   in
   "S{" ++ show_lst (M.elements m) ++ "}")%string.

Definition show_map_bool m nenv := show_map m nenv (fun (b : bool) => if b then "true" else "false")%string.
Definition show_map_nat m nenv := show_map m nenv show_nat.


Definition InlineSmallOrUncurried (bound:nat): InlineHeuristic (prod (M.t bool) (M.t nat)) :=
  CombineInlineHeuristic orb (InlineSmallIH bound) InlinedUncurriedMarked.

Definition inline_uncurry (e:exp) (s:M.t nat) (bound:nat) (d:nat) (c : comp_data) :=
    beta_contract_top _ (InlineSmallOrUncurried bound) e d (M.empty _, s) c false.

(* Fixpoint find_lambda_lifted (fds : fundefs) (s:M.t bool) : M.t bool :=  *)
(*   match fds with *)
(*   | Fcons f _ _ (Eapp g _ _) fds' => *)
(*     let s' := if (f =? g) then s else  M.set f true s in *)
(*     find_lambda_lifted fds' s' *)
(*   | _ => s *)
(*   end. *)


(* Definition InineLambdaLifted: InlineHeuristic (M.t bool) := *)
(*   {| update_funDef  := (fun (fds:fundefs) (sigma:r_map) (s:_) => *)
(*                           let s' := find_lambda_lifted fds s in *)
(*                           (s', s')); *)
(*      update_inFun := fun (f:var) (t:tag) (xs:list var) (e:exp) (sigma:r_map) (s:_) => (M.remove f s); *)
(*      update_App := fun (f:var) (t:tag) (ys:list var) (s:_) => *)
(*                      match M.get f s with *)
(*                      | Some true => (s, true) *)
(*                      | _ => (s, false) *)
(*                      end *)
(*   |}. *)
(* Definition inline_lambda_lifted (e:exp) (s:M.t nat) (bound:nat)  (d:nat) := *)
(*   beta_contract_top_debug _ show_map_bool InineLambdaLifted e d (M.empty bool). *)
