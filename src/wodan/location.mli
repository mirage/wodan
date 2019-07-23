type t

exception TooLarge
exception NotUnsigned

val zero : t
val one : t
val succ : t -> t
val add : t -> t -> t
val sub : t -> t -> t
val pred : t -> t
val compare : t -> t -> int
val shift_right_logical : t -> int -> t
val rem : t -> t -> t

val pp : Format.formatter -> t -> unit
val to_string : t -> string
val of_int64 : int64 -> t
val to_int64 : t -> int64

(* Provided until Bitv adds support for int64 indexes *)
val of_int : int -> t
(* Provided until Bitv adds support for int64 indexes *)
val to_int : t -> int
