(* Limited to max_int until Bitv adds support for int64 indexes *)
include Int64

exception TooLarge

exception NotUnsigned

let of_int64 v =
  if Int64.compare v (Int64.of_int Pervasives.max_int) > 0 then raise TooLarge
  else if Int64.compare v 0L < 0 then raise NotUnsigned
  else v

let of_int v = if v < 0 then raise NotUnsigned else Int64.of_int v

let to_int64 v = v

let pp fmt v = Format.fprintf fmt "L:%Ld" v
