
Require Export DDC.Language.SystemF2Effect.Ki.


(* Type Constructors. *)
Inductive tycon : Type :=
 | TyConFun  : tycon
 | TyConData : nat   -> ki -> tycon.
Hint Constructors tycon.


Fixpoint tycon_beq t1 t2 :=
 match t1, t2 with
 | TyConFun,       TyConFun       => true
 | TyConData n1 _, TyConData n2 _ => beq_nat n1 n2
 | _,              _              => false
 end.


Definition isTyConFun  (tc: tycon) : Prop :=
 match tc with
 | TyConFun      => True
 | TyConData _ _ => False
 end.
Hint Unfold isTyConFun.


Definition isTyConData (tc: tycon) : Prop :=
 match tc with
 | TyConFun      => False
 | TyConData _ _ => True
 end.
Hint Unfold isTyConData.