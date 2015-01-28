(* Trivial non-terminating function *)

Inductive I : Type := I_intro : I -> I.

Fixpoint non_terminating (x : I) { struct x } : I := non_terminating x.
