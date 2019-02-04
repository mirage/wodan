module type LRUValue = sig
  type t

  val discardable : t -> bool
end

module Make (K : Hashtbl.HashedType) (V : LRUValue) : sig
  (** The type for LRUs. *)
  type t

  (** The type for keyeys. *)
  type key = K.t

  (** The type for values. *)
  type value = V.t

  val create : int -> t
  (** [create n] creates an empty LRU of capacity [n]. *)

  val get_opt : t -> key -> value option
  (** [get_opt t id] gets the value bound to [id] in [t], wrapped in an option,
      and promotes the binding to most recently used. *)

  val peek_opt : t -> key -> value option
  (** Same as [get_opt], but does not promote the binding. *)

  val get : t -> key -> value
  (** Same as [get_opt] but raises Not_found if the binding does not exist. *)

  val peek : t -> key -> value
  (** Same as [peek_opt] but raises Not_found if the binding does not exist. *)

  val add : t -> key -> value -> unit
  (** [add t k v] adds the binding [k -> v] in [t]. *)

  val xadd : t -> key -> value -> unit
  (** [xadd t k v] adds the binding [k -> v] in [t] if [k] is free; otherwise
      raises Already_cached. *)

  val safe_add : t -> key -> value -> unit
  (** [safe_add t k v] adds the binding [k -> v] in [t] if the operation does
      not discard an [entry] such that [discardable entry] is [true]; otherwise
      raises [Too_small]. *)

  val safe_xadd : t -> key -> value -> unit
  (** [safe_xadd t k v] adds the binding [k -> v] in [t] if the operation does
      not discard an [entry] such that [discardable entry] is [true] (otherwise
      raises [Too_small]), and [k] is not already bound in [t] (otherwise
      raises [Already_cached]). *)

  val mem : t -> key -> bool
  (** [mem t k] checks whether [k] is bound in [t]. *)

  val items : t -> int
  (** [items t] is the number of bindings in [t]. *)

  val size : t -> int
  (** [size t] is the combined weight of the bindings in [t]. *)

  val capacity : t -> int
  (** [capacity t] is the maximum combined weight of the bindings before before
      the LRU starts discarding bindings. *)

  val lru : t -> (key * value) option
  (** [lru t] returns the least used binding in [t], or None if [t] is empty. *)
end
