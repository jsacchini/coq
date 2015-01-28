(* Trivial non-productive function *)

CoInductive U : Type := U_intro : U -> U.

CoFixpoint non_productive : U := non_productive.
