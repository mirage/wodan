type 'a t

val create: unit -> 'a t
val length: 'a t -> int
val is_empty: 'a t -> bool
val clear: 'a t -> unit
val find_opt: string -> 'a t -> 'a option
val mem: string -> 'a t -> bool
val add: string -> 'a -> 'a t -> unit
(* Like add, but a value must already exist *)
val update: string -> 'a -> 'a t -> unit
(* Like add, but a value cannot already exist *)
val xadd: string -> 'a -> 'a t -> unit
val remove: string -> 'a t -> unit
val iter: (string -> 'a -> unit) -> 'a t -> unit
val iter_range: string -> string -> (string -> 'a -> unit) -> 'a t -> unit
val iter_inclusive_range: string -> string -> (string -> 'a -> unit) -> 'a t -> unit
val fold: (string -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
val exists: (string -> 'a -> bool) -> 'a t -> bool
val min_binding: 'a t -> (string * 'a) option
val max_binding: 'a t -> (string * 'a) option
val find_first_opt: string -> 'a t -> (string * 'a) option
val find_last_opt: string -> 'a t -> (string * 'a) option
val split_off_after: string -> 'a t -> 'a t

