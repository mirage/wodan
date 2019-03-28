module type Params = sig
  module Key : Hashtbl.HashedType

  module Value : sig
    type t

    val discardable : t -> bool

    val on_discard : t -> (Key.t -> t) -> unit
  end
end

module Make (P : Params) : sig
  (** The type for LRUs. *)
  type t

  (** The type for keyeys. *)
  type key = P.Key.t

  (** The type for values. *)
  type value = P.Value.t

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
  (** [safe_xadd t k v] adds the binding [k -> v] in [t].
      If an [entry] is about to be discarded by this add then :
        - If [not (discadable entry)] then the call raises [Too_small]
        - Otherwise, [Value.on_discard entry (peek t)] is executed before the
        add *)

  val safe_xadd : t -> key -> value -> unit
  (** Same as [safe_add] but uses [xadd] instead, ie raises [Already_cached] if
      a binding with the same key already exists. *)

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
