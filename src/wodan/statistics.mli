type t

val create : unit -> t

val pp : Format.formatter -> t -> unit

val add_insert : t -> unit

val add_lookup : t -> unit

val add_range_search : t -> unit

val add_iter : t -> unit
