
Require Import KiJudge.
Require Import WellFormed.
Require Import Exp.
Require Import Base.


(* Lift type indices that are at least a certain depth. *)
Fixpoint liftTT (n: nat) (d: nat) (tt: ty) : ty :=
  match tt with
  | TCon _     => tt

  |  TVar ix
  => if bge_nat ix d
      then TVar (ix + n)
      else tt

  |  TForall t 
  => TForall (liftTT n (S d) t)

  |  TFun t1 t2
  => TFun    (liftTT n d t1) (liftTT n d t2)
  end.


(* Substitution of Types in Types. *)
Fixpoint substTT' (d: nat) (u: ty) (tt: ty) : ty 
 := match tt with
    |  TCon _     
    => tt
 
    | TVar ix
    => match compare ix d with
       | EQ => u
       | GT => TVar (ix - 1)
       | _  => TVar  ix
       end

    |  TForall t  
    => TForall (substTT' (S d) (liftTT 1 0 u) t)

    |  TFun t1 t2 
    => TFun (substTT' d u t1) (substTT' d u t2)
  end.


Definition substTT := substTT' 0.
Hint Unfold substTT.


(* Lifting Lemmas ***************************************************)
Lemma liftTT_insert
 :  forall ke ix t k1 k2
 ,  KIND ke t k1
 -> KIND (insert ix k2 ke) (liftTT 1 ix t) k1.
Proof.
 intros. gen ix ke k1.
 induction t; intros; simpl; inverts H; eauto.

 Case "TVar".
  breaka (bge_nat n ix).
  SCase "n >= ix".
   apply bge_nat_true in HeqX.
   apply KIVar. nnat. auto.

 Case "TForall".
  apply KIForall.
  rewrite insert_rewind. 
   apply IHt. auto.
Qed.


Lemma liftTT_push
 :  forall ke t k1 k2
 ,  KIND  ke         t             k1
 -> KIND (ke :> k2) (liftTT 1 0 t) k1.
Proof.
 intros.
 assert (ke :> k2 = insert 0 k2 ke). simpl. destruct ke; auto.
 rewrite H0. apply liftTT_insert. auto.
Qed.


(* Theorems *********************************************************)
(* Substitution of types in types preserves kinding.
   Must also subst new new type into types in env higher than ix
   otherwise indices ref subst type are broken.
   Resulting type env would not be well formed *)

Theorem subst_type_type_drop
 :  forall ix ke t1 k1 t2 k2
 ,  get ke ix = Some k2
 -> KIND ke t1 k1
 -> KIND (drop ix ke) t2 k2
 -> KIND (drop ix ke) (substTT' ix t2 t1) k1.
Proof.
 intros. gen ix ke t2 k1 k2.
 induction t1; intros; simpl; inverts H0; eauto.

 Case "TVar".
  destruct k1. destruct k2.
  fbreak_compare.
  SCase "n = ix".
   auto.

  SCase "n < ix".
   apply KIVar. rewrite <- H4. apply get_drop_above; auto.

  SCase "n > ix".
   apply KIVar. rewrite <- H4.
   destruct n.
    false. omega.
    simpl. nnat. apply get_drop_below. omega.

 Case "TForall".
  apply KIForall. rewrite drop_rewind.
  eapply IHt1. auto. simpl. eauto. 
  simpl. apply liftTT_push. auto.
Qed.


Theorem subst_type_type
 :  forall ke t1 k1 t2 k2
 ,  KIND (ke :> k2) t1 k1
 -> KIND ke         t2 k2
 -> KIND ke (substTT t2 t1) k1.
Proof.
 intros.
 assert (ke = drop 0 (ke :> k2)). auto. rewrite H1. clear H1.
 unfold substTT.
 eapply subst_type_type_drop; simpl; eauto.
Qed.

