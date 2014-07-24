(* Trivial non-terminating function *)

Fixpoint non_terminating (_ n : nat) { struct n } : False := non_terminating 0 n.
