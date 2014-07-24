Inductive I : nat -> Type :=
  C : forall n, I n -> I (S n)
| C1 : forall n, I n -> I n.

Definition F n (x : I (S n)) :=
  match x in I n0 where n0 := (S n)
        return I n with
      C n1 x0 => x0
    | C1 n1 x1 => x1 end.
