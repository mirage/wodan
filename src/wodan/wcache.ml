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

open Sexplib.Std

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

module Make (CK : Wcache_key.S) (CV : Wcache_value.S) : S = struct
  module CK = CK
  module CV = CV

  module LRU : Lru.M.S with type k = CK.t and type v = CV.t = Lru.M.Make(CK)(CV)

  module BlockIntervals = Diet.Make(struct
    include Int64
    let t_of_sexp = int64_of_sexp
    let sexp_of_t = sexp_of_int64
  end)

  exception AlreadyCached of CK.t
  exception OutOfSpace
  exception NeedsFlush

  type node_cache = {
    (* LRUKey.t -> lru_entry
     * all nodes are keyed by their alloc_id *)
    lru: LRU.t;
    mutable flush_root: CK.t option;
    mutable next_alloc_id: int64;
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

  let default_statistics = {
    inserts=0;
    lookups=0;
    range_searches=0;
    iters=0;
  }

  let lru_get lru alloc_id = LRU.find alloc_id lru
  let lru_peek lru alloc_id = LRU.find ~promote:false alloc_id lru

  let lookup_parent_link lru (entry : CV.t) =
    match entry.parent_key with
    | None -> None
    | Some parent_key ->
      match lru_peek lru parent_key with
      | None -> failwith "Missing parent"
      | Some parent_entry ->
        let children = Lazy.force parent_entry.children in
        let offset = CV.keyedmap_find entry.highest_key children in
        Some (parent_key, parent_entry, offset)
  
  let lru_xset lru alloc_id (value : CV.t) =
    if LRU.mem alloc_id lru then raise @@ AlreadyCached alloc_id;
    let would_discard = ((LRU.size lru) + (CV.weight value) > LRU.capacity lru) in
    (* assumes uniform weights, looks only at the bottom item *)
    if would_discard then begin
      match LRU.lru lru with
      | Some (_alloc_id, entry) when entry.flush_info <> None ->
        failwith "Would discard dirty data" (* TODO expose this as a proper API value *)
      | Some (_alloc_id, entry) -> begin
        match lookup_parent_link lru entry with
        | None -> failwith "Would discard a root key, LRU too small for tree depth"
        | Some (_parent_key, parent_entry, _offset) ->
          CV.KeyedMap.remove entry.highest_key parent_entry.children_alloc_ids
        end
      |_ -> failwith "LRU capacity is too small"
    end;
    LRU.add alloc_id value lru
  
  let lru_create capacity = LRU.create capacity

  let bitv_create64 off bit =
    if Int64.compare off (Int64.of_int max_int) > 0 then
      failwith (Printf.sprintf "Size %Ld too large for a Bitv" off)
    else
      Bitv.create (Int64.to_int off) bit

  let bitv_set64 vec off bit =
    Bitv.set vec (Int64.to_int off) bit (* Safe as long as bitv_create64 is used *)

  let bitv_get64 vec off =
    Bitv.get vec (Int64.to_int off) (* Safe as long as bitv_create64 is used *)

  let bitv_len64 vec = Int64.of_int @@ Bitv.length vec

  let next_logical_novalid cache logical =
    let log1 = Int64.succ logical in
    if log1 = cache.logical_size then 1L else log1
  
  let next_logical_alloc_valid cache =
    if cache.free_count = 0L then failwith "Out of space"; (* Not the same as OutOfSpace *)
    let rec after log =
      if not @@ bitv_get64 cache.space_map log then
        log
      else
        after @@ next_logical_novalid cache log
    in
    let loc = after cache.next_logical_alloc in
    cache.next_logical_alloc <- next_logical_novalid cache loc;
    loc
  
  let next_alloc_id cache =
    let r = cache.next_alloc_id in
    cache.next_alloc_id <- Int64.succ cache.next_alloc_id;
    r

  let next_generation cache =
    let r = cache.next_generation in
    cache.next_generation <- Int64.succ cache.next_generation;
    r

  let rec _reserve_dirty_rec cache alloc_id new_count dirty_count =
    (*Logs.debug (fun m -> m "_reserve_dirty_rec %Ld" alloc_id);*)
    match lru_get cache.lru alloc_id with
    | None -> failwith "Missing LRU key"
    | Some entry -> begin
      match entry.flush_info with
      | Some _di -> ()
      | None -> begin
        match entry.cached_node with
        | `Root -> ()
        | `Child ->
          match entry.parent_key with
          | Some parent_key -> begin
            match lru_get cache.lru parent_key with
            | None -> failwith "missing parent_entry"
            | Some _parent_entry -> _reserve_dirty_rec cache parent_key new_count dirty_count
          end
          | None -> failwith "entry.parent_key inconsistent (no parent)";
      end;
      begin
        match entry.prev_logical with
        | None -> new_count := Int64.succ !new_count
        | Some _plog -> dirty_count := Int64.succ !dirty_count
      end;
    end
  
  let _reserve_dirty cache alloc_id new_count depth =
    (*Logs.debug (fun m -> m "_reserve_dirty %Ld" alloc_id);*)
    let new_count = ref new_count in
    let dirty_count = ref 0L in
    _reserve_dirty_rec cache alloc_id new_count dirty_count;
    (*Logs.debug (fun m -> m "_reserve_dirty %Ld free %Ld allocs N %Ld D %Ld counter N %Ld D %Ld depth %Ld"
             alloc_id cache.free_count cache.new_count cache.dirty_count !new_count !dirty_count depth);*)
    if Int64.(compare cache.free_count @@ add cache.dirty_count @@ add !dirty_count @@ add cache.new_count !new_count) < 0 then begin
      if Int64.(compare cache.free_count @@ add !dirty_count @@ add cache.new_count @@ add !new_count @@ succ depth) >= 0 then
        raise NeedsFlush (* flush and retry, it will succeed *)
      else
        raise OutOfSpace (* flush if you like, but retrying will not succeed *)
    end

  let rec _mark_dirty cache alloc_id : CV.flush_info =
    (*Logs.debug (fun m -> m "_mark_dirty %Ld" alloc_id);*)
    match lru_get cache.lru alloc_id with
    | None -> failwith "Missing LRU key"
    | Some entry -> begin
      match entry.flush_info with
      | Some di -> di
      | None -> begin
        match entry.cached_node with
        | `Root -> begin
          match cache.flush_root with
          | None -> cache.flush_root <- Some alloc_id
          | _ -> failwith "flush_root inconsistent"
        end
        | `Child ->
          match entry.parent_key with
          | Some parent_key -> begin
            match lru_get cache.lru parent_key with
            | None -> failwith "missing parent_entry"
            | Some _parent_entry ->
              let parent_di = _mark_dirty cache parent_key in
              begin
                if CV.KeyedMap.exists (fun _k lk -> lk = alloc_id) parent_di.flush_children then
                  failwith "dirty_node inconsistent"
                else
                  CV.KeyedMap.add entry.highest_key alloc_id parent_di.flush_children
              end
          end
          | None -> failwith "entry.parent_key inconsistent (no parent)";
      end;
        let di = { CV.flush_children=CV.KeyedMap.create (); } in
        entry.flush_info <- Some di;
        begin
          match entry.prev_logical with
          | None ->
            cache.new_count <- Int64.succ cache.new_count;
            if Int64.(compare (add cache.new_count cache.dirty_count) cache.free_count) > 0 then
              failwith "Out of space"; (* Not the same as OutOfSpace *)
          | Some _plog ->
            cache.dirty_count <- Int64.succ cache.dirty_count;
            if Int64.(compare (add cache.new_count cache.dirty_count) cache.free_count) > 0 then
              failwith "Out of space";
        end;
        di
    end

end