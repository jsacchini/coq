Set Implicit Arguments.

Inductive vec A : nat -> Type :=
  | nil : vec A 0
  | cons : forall n, A -> vec A n -> vec A (S n).

Lemma fib : forall n, vec nat n.
Proof.
  induction n.
  exact (nil nat).
  case_eq n.
  intro; exact (cons 0 (nil nat)).
  intros.
  case_eq n0.
  intro; exact (cons 1 (cons 0 (nil nat))).
  intros.
  rewrite H in *.
  rewrite H0 in *.
  inversion IHn.
  inversion H3.
  exact (cons (H2+H5) IHn).
Defined.

Eval compute in (fib 10).


Definition head A n (v : vec A (S n)) :=
  match v in vec _ n0 where n0 := S n
        return A with
    | cons h t => h
  end.

Lemma head_pf : forall A n, vec A (S n) -> A.
Proof.
intros A n v; depcase v; auto.
Qed.

Definition tail A n (v : vec A (S n)) :=
  match v in vec _ n0 where n0 := S n
        return vec A n with
    | cons  h t => t
  end.

Lemma tail_pf : forall A n, vec A (S n) -> vec A n.
Proof.
  intros A n v; depcase v; auto.
Qed.

Print tail.
Print head_pf.

Eval compute in (fib 9).
Eval compute in (tail (tail (tail (fib 9)))).
Eval compute in (head (tail (tail (fib 9)))).
