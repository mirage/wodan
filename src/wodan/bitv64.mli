(** Bitv64 is a wrapper around Bitv, for easier use with int64 indexes and
    sizes. *)

type t
(** The type for [int64] indexed [Bitv]s *)

val create : int64 -> bool -> t
(** [create n b] creates a new bit vector of length [n],
    initialized with [b].
    [n] must be smaller than [max_int], otherwise raises Invalid_argument. *)

val set : t -> int64 -> bool -> unit
(** [Bitv.set v n b] sets the [n]th bit of [v] to the value [b]. *)

val get : t -> int64 -> bool
(** [Bitv.get v n] returns the [n]th bit of [v]. *)

val length : t -> int64
(** [length] returns the length of the given vector. *)

val iter : (bool -> unit) -> t -> unit
(** [iter f v] applies [f] to every element in [v]. *)

val iteri : (int64 -> bool -> unit) -> t -> unit
(** [iteri] is like [iter], but applies f to the index of the element,
    as first argument, and to the element itself, as second argument. *)
