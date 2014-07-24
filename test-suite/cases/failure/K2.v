Inductive path A (x:A) : forall B, B -> Type :=
  refl : path A x A x.

Definition K A (P : A -> Type) (x y : A) (H : P x) (p: path A x A y) :=
  match p in path _ _ B y0 where B:=A, y0:=y
        return P y0
  with refl _ _ => H end.
