(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
(*  Copyright 2019 Nicolas Assouad <nicolas@tarides.com>                          *)
(*                                                                                   *)
(*  Permission to use, copy, modify, and/or distribute this software for any         *)
(*  purpose with or without fee is hereby granted, provided that the above           *)
(*  copyright notice and this permission notice appear in all copies.                *)
(*                                                                                   *)
(*  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH    *)
(*  REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND  *)
(*  FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,         *)
(*  INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM      *)
(*  LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR    *)
(*  OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR           *)
(*  PERFORMANCE OF THIS SOFTWARE.                                                    *)
(*                                                                                   *)
(*************************************************************************************)

module type OrderedType = sig
  type t
  val compare : t -> t -> int
end

module type S = sig
  type key
  type 'a t

  val create: unit -> 'a t
  val length: 'a t -> int
  val is_empty: 'a t -> bool
  val clear: 'a t -> unit
  val find_opt: key -> 'a t -> 'a option
  val mem: key -> 'a t -> bool
  val add: key -> 'a -> 'a t -> unit
  (* Map a single value through a function in place *)
  val map1: key -> ('a option -> 'a option) -> 'a t -> unit
  (* Like add, but a value must already exist *)
  val update: key -> 'a -> 'a t -> unit
  (* Like add, but a value cannot already exist *)
  val xadd: key -> 'a -> 'a t -> unit
  val remove: key -> 'a t -> unit
  val iter: (key -> 'a -> unit) -> 'a t -> unit
  val iter_range: key -> key -> (key -> 'a -> unit) -> 'a t -> unit
  val iter_inclusive_range: key -> key -> (key -> 'a -> unit) -> 'a t -> unit
  val carve_inclusive_range: key -> key -> 'a t -> 'a t
  val fold: (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
  val exists: (key -> 'a -> bool) -> 'a t -> bool
  val min_binding: 'a t -> (key * 'a) option
  val max_binding: 'a t -> (key * 'a) option
  val find_first_opt: key -> 'a t -> (key * 'a) option
  val find_last_opt: key -> 'a t -> (key * 'a) option
  val split_off_after: key -> 'a t -> 'a t
  val swap: 'a t -> 'a t -> unit
end

module Make (Ord : OrderedType) : S with type key = Ord.t