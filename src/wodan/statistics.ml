type t = {
  mutable inserts : int;
  mutable lookups : int;
  mutable range_searches : int;
  mutable iters : int;
}

let create () = {inserts = 0; lookups = 0; range_searches = 0; iters = 0}

let pp fmt {inserts; lookups; range_searches; iters} =
  Format.fprintf fmt "Ops: %d inserts %d lookups %d range searches %d iters"
    inserts lookups range_searches iters

let add_insert t = t.inserts <- succ t.inserts

let add_lookup t = t.lookups <- succ t.lookups

let add_range_search t = t.range_searches <- succ t.range_searches

let add_iter t = t.iters <- succ t.iters
