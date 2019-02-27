type t = Bitv.t

let create size bit =
  if Int64.compare size (Int64.of_int max_int) > 0 then
    raise (Invalid_argument "Bitv64.create");
  Bitv.create (Int64.to_int size) bit

let set vec off bit = Bitv.set vec (Int64.to_int off) bit

let get vec off = Bitv.get vec (Int64.to_int off)

let length vec = Int64.of_int (Bitv.length vec)

let iter = Bitv.iter

let iteri f t = Bitv.iteri (fun i b -> f (Int64.of_int i) b) t
