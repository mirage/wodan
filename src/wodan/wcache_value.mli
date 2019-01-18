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

  type ckey = CK.t
  type key = string

  module KeyedMap : Wodan_btreemap.S with type key = key
  module KeyedSet : Set.S with type elt = key

  type t = {
    cached_node: node;
    mutable parent_key: ckey option;
    (* A node is flushable iff it's referenced from flush_root
       through a flush_children map.
       We use an option here to make checking for flushability faster.
       A flushable node is either new or dirty, but not both. *)
    mutable flush_info: flush_info option;
    (* Use offsets so that data isn't duplicated *)
    mutable children: (ckey KeyedMap.t) Lazy.t;
    (* Don't reference nodes directly, always go through the
     * LRU to bump recently accessed nodes *)
    mutable children_alloc_ids: ckey KeyedMap.t;
    mutable highest_key: key;
    raw_node: Cstruct.t;
    io_data: Cstruct.t list;
    logdata: logdata_index;
    childlinks: childlinks;
    mutable prev_logical: ckey option;
    (* depth counted from the leaves; mutable on the root only *)
    mutable rdepth: int32;
  }

  and node = [
    | `Root
    | `Child
  ]

  and flush_info = {mutable flush_children: int64 KeyedMap.t;}

  and logdata_index = {
    mutable logdata_contents: string KeyedMap.t;
    mutable value_end: int;
    mutable old_value_end: int;
  }

  and childlinks = {mutable childlinks_offset: int;}

  val weight : t -> int

  val header_size : node -> int

  val keyedmap_find : key -> 'a KeyedMap.t -> 'a
  val keyedmap_keys : 'a KeyedMap.t -> key list
end

module Make (K : Wkey.S) : S with type key = K.t