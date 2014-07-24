Inductive vec A : nat -> Type :=
  | nil : vec A 0
  | cons : forall n, A -> vec A n -> vec A (S n).


Definition tail2 A n (v : vec A (S n)) :=
  match v in vec _ n0 where n0 := S n
        return vec A n0 with
    | cons _ _ h t => t
  end.
