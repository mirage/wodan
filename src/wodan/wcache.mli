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

module type S = sig
  module CK : Wcache_key.S
  module CV : Wcache_value.S

  module LRU : Lru.M.S with type k = CK.t and type v = CV.t
  module BlockIntervals : Diet.INTERVAL_SET with type elt = CK.t

  exception AlreadyCached of CK.t
  exception OutOfSpace
  exception NeedsFlush

  type node_cache = {
    (* LRUKey.t -> lru_entry
     * all nodes are keyed by their alloc_id *)
    lru: LRU.t;
    mutable flush_root: CK.t option;
    mutable next_alloc_id: CK.t;
    (* The next generation number we'll allocate *)
    mutable next_generation: int64;
    (* The next logical address we'll allocate (if free) *)
    mutable next_logical_alloc: int64;
    (* Count of free blocks on disk *)
    mutable free_count: int64;
    mutable new_count: int64;
    mutable dirty_count: int64;
    fsid: string;
    logical_size: int64;
    (* Logical -> bit.  Zero iff free. *)
    space_map: Bitv.t;
    scan_map: Bitv.t option;
    mutable freed_intervals: BlockIntervals.t;
    statistics: statistics;
  }

  and statistics = {
    mutable inserts: int;
    mutable lookups: int;
    mutable range_searches: int;
    mutable iters: int;
  }

  val default_statistics : statistics

  val lru_get : LRU.t -> CK.t -> CV.t option
  val lru_peek : LRU.t -> CK.t -> CV.t option

  val lookup_parent_link : LRU.t -> CV.t -> (CK.t * CV.t * int64) option

  val lru_xset : LRU.t -> CK.t -> CV.t -> unit

  val _reserve_dirty : node_cache -> CK.t -> int64 -> int64 -> unit

  val lru_create : int -> LRU.t

  val bitv_create64 : int64 -> bool -> Bitv.t
  val bitv_set64 : Bitv.t -> int64 -> bool -> unit
  val bitv_get64 : Bitv.t -> int64 -> bool
  val bitv_len64 : Bitv.t -> int64

  val next_logical_novalid : node_cache -> int64 -> int64
  val next_logical_alloc_valid : node_cache -> int64
  val next_alloc_id : node_cache -> CK.t
  val next_generation : node_cache -> int64

  val _mark_dirty : node_cache -> CK.t -> CV.flush_info
end

module Make (CK : Wcache_key.S) (CV : Wcache_value.S) : S