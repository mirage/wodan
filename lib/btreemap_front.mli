type t

val create: unit -> t
val length: t -> int
val is_empty: t -> bool
val clear: t -> unit
val find_opt: string -> t -> int64 option
val mem: string -> t -> bool
val add: string -> int64 -> t -> unit
(* Like add, but a value must already exist *)
val update: string -> int64 -> t -> unit
(* Like add, but a value cannot already exist *)
val xadd: string -> int64 -> t -> unit
val remove: string -> t -> unit
val iter: (string -> int64 -> unit) -> t -> unit
val iter_range: string -> string -> (string -> int64 -> unit) -> t -> unit
val iter_inclusive_range: string -> string -> (string -> int64 -> unit) -> t -> unit
val fold: (string -> int64 -> 'b -> 'b) -> t -> 'b -> 'b
val exists: (string -> int64 -> bool) -> t -> bool
val min_binding: t -> (string * int64) option
val max_binding: t -> (string * int64) option
val find_first_opt: string -> t -> (string * int64) option
val find_last_opt: string -> t -> (string * int64) option
val split_off_after: string -> t -> t

