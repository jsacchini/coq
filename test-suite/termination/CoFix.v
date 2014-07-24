(* Trivial non-productive function *)

Require Import Streams.

CoFixpoint non_productive : Stream nat := non_productive.
