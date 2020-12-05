(** A generic interface for statistics *)
module type STATISTICS = sig
  type t

  val pp : Format.formatter -> t -> unit

  val data : t -> Metrics.Data.t
end

(** stats of high-level Wodan operations *)
module HighLevel : sig
  (* A very reduced, read-only view *)
  type t = {
    mutable inserts : int;
    mutable lookups : int;
    mutable range_searches : int;
    mutable iters : int;
  }

  include STATISTICS with type t := t

  val create : unit -> t
end

(** Stats of operations on the backing store *)
module LowLevel : sig
  (* A very reduced, read-only view *)
  type t = {
    mutable reads : int;
    mutable writes : int;
    mutable discards : int;
    mutable barriers : int;
    block_size : int;
  }

  include STATISTICS with type t := t

  val create : int -> t
end

(** Stats of amplification between high-level and low-level operations *)
module Amplification : sig
  include STATISTICS

  val build : HighLevel.t -> LowLevel.t -> t
end
