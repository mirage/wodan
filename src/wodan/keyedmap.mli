module type OrderedType = sig
  type t

  val compare : t -> t -> int
end

module Make (Ord : OrderedType) : sig
  (** The type for maps  *)
  type 'a t

  (** The type for keys  *)
  type key = Ord.t

  val create : unit -> 'a t
  (** Creates a new empty map *)

  val length : 'a t -> int
  (** Returns the length of the map  *)

  val clear : 'a t -> unit
  (** Clears the map  *)

  val is_empty : 'a t -> bool
  (** [is_empty m] returns whether map [m] is empty *)

  val find : 'a t -> key -> 'a
  (** [find m x] returns the binding of x in [m] or raises [Not_found]
      if [x] is not bind.  *)

  val find_opt : 'a t -> key -> 'a option
  (** Same as [find] but wrapped in an option  *)

  val min_binding : 'a t -> key * 'a
  (** Returns the binding with the minimum key, or raises Not_found if the map
      is empty. *)

  val max_binding : 'a t -> key * 'a
  (** Returns the binding with the maximum key, or raises Not_found if the map
      is empty. *)

  val find_first : 'a t -> key -> key * 'a
  (** [find_first_opt m k] finds the binding with the smallest key that
      is greater than [k], or raises [Not_found] if empty *)

  val find_last : 'a t -> key -> key * 'a
  (** [find_first_opt m k] finds the binding with the greatest key that
      is smaller than [k], or raises [Not_found] if empty *)

  val find_first_opt : 'a t -> key -> (key * 'a) option
  (** Same as [find_first] but wrapped in an option *)

  val find_last_opt : 'a t -> key -> (key * 'a) option
  (** Same as [find_last] but wrapped in an option *)

  val mem : 'a t -> key -> bool
  (** [mem m x] checks whether [x] is bind in [m]  *)

  val exists : (key -> 'a -> bool) -> 'a t -> bool
  (** [exists f m] checks whether there exists a binding in [m]
      satisfying the predicate [f] *)

  val add : 'a t -> key -> 'a -> unit
  (** [add m k v] adds a binding from [k] to [v] in [m], replacing
      the previous binding if any*)

  val remove : 'a t -> key -> unit
  (** [remove m k] removes the binding of [k] in [m] *)

  val replace_existing : 'a t -> key -> 'a -> unit
  (** [replace_existing m k v] replaces the binding of [k] in
      [m] with the value [v] if any, otherwise raises [Not_found] *)

  val xadd : 'a t -> key -> 'a -> unit
  (** [xadd m k v] adds a binding from [k] to [v], or raises
      [Already_exists] if there is already one *)

  val update : 'a t -> key -> ('a option -> 'a option) -> unit
  (** [update m x f] returns a map containing the same bindings as [m], except
      for the binding of [x]. Depending on the value of y where y is
      [f (find_opt x m)], the binding of [x] is added, removed or updated.
      If y is [None], the binding is removed if it exists; otherwise, if y is
      [Some z] then [x] is associated to [z] in the resulting map. If [x] was
      already bound in [m] to a value that is physically equal to [z], [m] is
      left unchanged *)

  val keys : 'a t -> key list
  (** Returns the list of the keys of the map, in ascending order *)

  val iter : (key -> 'a -> unit) -> 'a t -> unit
  (** [iter f m] applies [f] to all bindings in [m] *)

  val fold : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
  (** [fold f m a] computes [(f kN dN ... (f k1 d1 a)...)], where [k1 ... kN]
      are the keys of all bindings in [m] (in increasing order), and
      [d1 ... dN] are the associated data. *)

  val iter_range : (key -> 'a -> unit) -> 'a t -> key -> key -> unit
  (** [iter f m start stop] applies [f] to all bindings [(x, d)] in [m] such
      that start <= x < stop *)

  val iter_inclusive_range : (key -> 'a -> unit) -> 'a t -> key -> key -> unit
  (** [iter f m start stop] applies [f] to all bindings [(x, d)] in [m] such
      that start <= x <= stop *)

  val split_off_after : 'a t -> key -> 'a t
  (** [split_off_after m k] removes all the bindings [(x, v)] in [m] such
      that [x > k] and returns them in a new map *)

  val split_off_le : 'a t -> key -> 'a t
  (** [split_off_le m k] removes all the bindings [(x, v)] in [m] such that
      [x <= k] and returns them in a new map *)

  val carve_inclusive_range : 'a t -> key -> key -> 'a t
  (** [carve_inclusive_range m start stop] removes all the bindings [(x, v)] in
      [m] such that [x < start] or [stop < x] and returns them in a new map *)

  val swap : 'a t -> 'a t -> unit
  (** [swap m1 m2] swaps the bindings of [m1] and [m2] *)

  val copy_in : 'a t -> 'a t -> unit
  (** [copy_in m1 m2] clears [m2] and copies the contents of [m1] in it *)
end
