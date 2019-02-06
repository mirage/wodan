(******************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                   *)
(*                                                                            *)
(* Permission to use, copy, modify, and/or distribute this software for any   *)
(* purpose with or without fee is hereby granted, provided that the above     *)
(* copyright notice and this permission notice appear in all copies.          *)
(*                                                                            *)
(* THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES   *)
(* WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF           *)
(* MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR    *)
(* ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES     *)
(* WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN      *)
(* ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR *)
(* IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.                *)
(*                                                                            *)
(******************************************************************************)

open Lwt.Infix
open Sexplib.Std

let superblock_magic = "MIRAGE KVFS \xf0\x9f\x90\xaa"

let superblock_version = 1l

let max_dirty = 128

exception BadMagic

exception BadVersion

exception BadFlags

exception BadCRC of int64

exception BadParams

exception ReadError

exception WriteError

exception OutOfSpace

exception NeedsFlush

exception BadKey of string

exception ValueTooLarge of string

exception BadNodeType of int

exception BadNodeFSID of string

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK

  val discard : t -> int64 -> int64 -> (unit, write_error) result io
end

module BlockCompat (B : Mirage_types_lwt.BLOCK) : EXTBLOCK with type t = B.t =
struct
  include B

  let discard _ _ _ = Lwt.return @@ Ok ()
end

(* Incompatibility flags *)
let sb_incompat_rdepth = 1l

let sb_incompat_fsid = 2l

let sb_incompat_value_count = 4l

let sb_required_incompat =
  Int32.logor sb_incompat_rdepth
  @@ Int32.logor sb_incompat_fsid sb_incompat_value_count

[@@@warning "-32"]

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct
type superblock = {
  magic : uint8_t; [@len 16]
  (* major version, all later fields may change if this does *)
  version : uint32_t;
  compat_flags : uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags : uint32_t;
  block_size : uint32_t;
  key_size : uint8_t;
  first_block_written : uint64_t;
  logical_size : uint64_t;
  (* FSID is UUID-sized (128 bits) *)
  fsid : uint8_t; [@len 16]
  reserved : uint8_t; [@len 443]
  crc : uint32_t
}
[@@little_endian]]

let () = assert (String.length superblock_magic = 16)

let () = assert (sizeof_superblock = 512)

let sizeof_crc = 4

[%%cstruct
type anynode_hdr = {
  nodetype : uint8_t;
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t
}
[@@little_endian]]

let () = assert (sizeof_anynode_hdr = 29)

[%%cstruct
type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype : uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t;
  depth : uint32_t
}
[@@little_endian]]

let () = assert (sizeof_rootnode_hdr = 33)

(* Contents: logged data, and child node links *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
 * crc *)

[%%cstruct
type childnode_hdr = {
  (* nodetype = 2 *)
  nodetype : uint8_t;
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t
}
[@@little_endian]]

let () = assert (sizeof_childnode_hdr = 29)

(* Contents: logged data, and child node links *)
(* Layout: see above *)

[@@@warning "+32"]

let sizeof_datalen = 2

let sizeof_logical = 8

let make_fanned_io_list size cstr =
  let r = ref [] in
  let l = Cstruct.len cstr in
  let rec iter off =
    if off = 0 then ()
    else
      let off = off - size in
      r := Cstruct.sub cstr off size :: !r;
      iter off
  in
  iter l; !r

let _sb_io block_io = Cstruct.sub block_io 0 sizeof_superblock

type statistics = {
  mutable inserts : int;
  mutable lookups : int;
  mutable range_searches : int;
  mutable iters : int
}

let default_statistics =
  {inserts = 0; lookups = 0; range_searches = 0; iters = 0}

type childlinks = {
  (* starts at block_size - sizeof_crc, if there are no children *)
  mutable childlinks_offset : int
}

type node =
  [ `Root
  | `Child ]

let header_size = function
  | `Root ->
      sizeof_rootnode_hdr
  | `Child ->
      sizeof_childnode_hdr

let string_dump key = Cstruct.hexdump @@ Cstruct.of_string key

let src = Logs.Src.create "wodan" ~doc:"logs Wodan operations"

module Logs = (val Logs.src_log src : Logs.LOG)

module BlockIntervals = Diet.Make (struct
  include Int64

  let t_of_sexp = int64_of_sexp

  let sexp_of_t = sexp_of_int64
end)

let unwrap_opt = function
  | None ->
      raise Not_found
  | Some v ->
      v

module KeyedMap = Wodan_btreemap

(*module KeyedMap = Btreemap*)
let keyedmap_find k map = unwrap_opt @@ KeyedMap.find_opt k map

let keyedmap_keys map = KeyedMap.fold (fun k _v acc -> k :: acc) map []

module KeyedSet = Set.Make (String)

module LRUKey = struct
  type t = int64

  let hash = Hashtbl.hash

  let equal = Int64.equal
end

type logdata_index = {
  mutable logdata_contents : string KeyedMap.t;
  mutable value_end : int;
  mutable old_value_end : int
}

type flush_info = {mutable flush_children : int64 KeyedMap.t}

type lru_entry = {
  cached_node : node;
  mutable parent_key : LRUKey.t option;
  (* A node is flushable iff it's referenced from flush_root
     through a flush_children map.
     We use an option here to make checking for flushability faster.
     A flushable node is either new or dirty, but not both. *)
  mutable flush_info : flush_info option;
  (* Use offsets so that data isn't duplicated *)
  mutable children : int64 KeyedMap.t Lazy.t;
  (* Don't reference nodes directly, always go through the
 * LRU to bump recently accessed nodes *)
  mutable children_alloc_ids : int64 KeyedMap.t;
  mutable highest_key : string;
  raw_node : Cstruct.t;
  io_data : Cstruct.t list;
  logdata : logdata_index;
  childlinks : childlinks;
  mutable prev_logical : int64 option;
  (* depth counted from the leaves; mutable on the root only *)
  mutable rdepth : int32
}

module LRUValue = struct
  type t = lru_entry

  let weight _val = 1
end

module LRU = Lru.M.Make (LRUKey) (LRUValue)

let lru_get lru alloc_id = LRU.find alloc_id lru

let lru_peek lru alloc_id = LRU.find ~promote:false alloc_id lru

exception AlreadyCached of LRUKey.t

let lookup_parent_link lru entry =
  match entry.parent_key with
  | None ->
      None
  | Some parent_key -> (
    match lru_peek lru parent_key with
    | None ->
        failwith "Missing parent"
    | Some parent_entry ->
        let children = Lazy.force parent_entry.children in
        let offset = keyedmap_find entry.highest_key children in
        Some (parent_key, parent_entry, offset) )

(* Exclusive set *)
let lru_xset lru alloc_id value =
  if LRU.mem alloc_id lru then raise @@ AlreadyCached alloc_id;
  let would_discard =
    LRU.size lru + LRUValue.weight value > LRU.capacity lru
  in
  (* assumes uniform weights, looks only at the bottom item *)
  ( if would_discard then
    match LRU.lru lru with
    | Some (_alloc_id, entry)
      when entry.flush_info <> None ->
        failwith "Would discard dirty data"
        (* TODO expose this as a proper API value *)
    | Some (_alloc_id, entry) -> (
      match lookup_parent_link lru entry with
      | None ->
          failwith "Would discard a root key, LRU too small for tree depth"
      | Some (_parent_key, parent_entry, _offset) ->
          KeyedMap.remove entry.highest_key parent_entry.children_alloc_ids )
    | _ ->
        failwith "LRU capacity is too small" );
  LRU.add alloc_id value lru

let lru_create capacity = LRU.create capacity

type node_cache = {
  (* LRUKey.t -> lru_entry
   * all nodes are keyed by their alloc_id *)
  lru : LRU.t;
  mutable flush_root : LRUKey.t option;
  mutable next_alloc_id : int64;
  (* The next generation number we'll allocate *)
  mutable next_generation : int64;
  (* The next logical address we'll allocate (if free) *)
  mutable next_logical_alloc : int64;
  (* Count of free blocks on disk *)
  mutable free_count : int64;
  mutable new_count : int64;
  mutable dirty_count : int64;
  fsid : string;
  logical_size : int64;
  (* Logical -> bit.  Zero iff free. *)
  space_map : Bitv.t;
  scan_map : Bitv.t option;
  mutable freed_intervals : BlockIntervals.t;
  statistics : statistics
}

let bitv_create64 off bit =
  if Int64.compare off (Int64.of_int max_int) > 0 then
    failwith (Printf.sprintf "Size %Ld too large for a Bitv" off);
  Bitv.create (Int64.to_int off) bit

let bitv_set64 vec off bit = Bitv.set vec (Int64.to_int off) bit

(* Safe as long as bitv_create64 is used *)

let bitv_get64 vec off = Bitv.get vec (Int64.to_int off)

(* Safe as long as bitv_create64 is used *)

let bitv_len64 vec = Int64.of_int @@ Bitv.length vec

let next_logical_novalid cache logical =
  let log1 = Int64.succ logical in
  if log1 = cache.logical_size then 1L else log1

let next_logical_alloc_valid cache =
  if cache.free_count = 0L then failwith "Out of space";
  (* Not the same as OutOfSpace *)
  let rec after log =
    if not @@ bitv_get64 cache.space_map log then log
    else after @@ next_logical_novalid cache log
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

let int64_pred_nowrap va =
  if Int64.compare va 0L <= 0 then failwith "Int64 wrapping down to negative"
  else Int64.pred va

type insertable =
  | InsValue of string
  | InsChild of int64 * int64 option

(* loc, alloc_id *)

(*|InsTombstone*)
(* use empty values for now *)

type insert_space =
  | InsSpaceValue of int
  | InsSpaceChild of int

let rec _reserve_dirty_rec cache alloc_id new_count dirty_count =
  (*Logs.debug (fun m -> m "_reserve_dirty_rec %Ld" alloc_id);*)
  match lru_get cache.lru alloc_id with
  | None ->
      failwith "Missing LRU key"
  | Some entry -> (
    match entry.flush_info with
    | Some _di ->
        ()
    | None -> (
        ( match entry.cached_node with
        | `Root ->
            ()
        | `Child -> (
          match entry.parent_key with
          | Some parent_key -> (
            match lru_get cache.lru parent_key with
            | None ->
                failwith "missing parent_entry"
            | Some _parent_entry ->
                _reserve_dirty_rec cache parent_key new_count dirty_count )
          | None ->
              failwith "entry.parent_key inconsistent (no parent)" ) );
        match entry.prev_logical with
        | None ->
            new_count := Int64.succ !new_count
        | Some _plog ->
            dirty_count := Int64.succ !dirty_count ) )

let _reserve_dirty cache alloc_id new_count depth =
  (*Logs.debug (fun m -> m "_reserve_dirty %Ld" alloc_id);*)
  let new_count = ref new_count in
  let dirty_count = ref 0L in
  _reserve_dirty_rec cache alloc_id new_count dirty_count;
  (*Logs.debug (fun m -> m "_reserve_dirty %Ld free %Ld allocs N %Ld D %Ld counter N %Ld D %Ld depth %Ld"
             alloc_id cache.free_count cache.new_count cache.dirty_count !new_count !dirty_count depth);*)
  if
    Int64.(
      compare cache.free_count
      @@ add cache.dirty_count
      @@ add !dirty_count
      @@ add cache.new_count !new_count)
    < 0
  then
    if
      Int64.(
        compare cache.free_count
        @@ add !dirty_count
        @@ add cache.new_count
        @@ add !new_count
        @@ succ depth)
      >= 0
    then raise NeedsFlush (* flush and retry, it will succeed *)
    else raise OutOfSpace

(* flush if you like, but retrying will not succeed *)

let rec _mark_dirty cache alloc_id : flush_info =
  (*Logs.debug (fun m -> m "_mark_dirty %Ld" alloc_id);*)
  match lru_get cache.lru alloc_id with
  | None ->
      failwith "Missing LRU key"
  | Some entry -> (
    match entry.flush_info with
    | Some di ->
        di
    | None ->
        ( match entry.cached_node with
        | `Root -> (
          match cache.flush_root with
          | None ->
              cache.flush_root <- Some alloc_id
          | _ ->
              failwith "flush_root inconsistent" )
        | `Child -> (
          match entry.parent_key with
          | Some parent_key -> (
            match lru_get cache.lru parent_key with
            | None ->
                failwith "missing parent_entry"
            | Some _parent_entry ->
                let parent_di = _mark_dirty cache parent_key in
                if
                  KeyedMap.exists
                    (fun _k lk -> lk = alloc_id)
                    parent_di.flush_children
                then failwith "dirty_node inconsistent"
                else
                  KeyedMap.add entry.highest_key alloc_id
                    parent_di.flush_children )
          | None ->
              failwith "entry.parent_key inconsistent (no parent)" ) );
        let di = {flush_children = KeyedMap.create ()} in
        entry.flush_info <- Some di;
        ( match entry.prev_logical with
        | None ->
            cache.new_count <- Int64.succ cache.new_count;
            if
              Int64.(
                compare
                  (add cache.new_count cache.dirty_count)
                  cache.free_count)
              > 0
            then failwith "Out of space" (* Not the same as OutOfSpace *)
        | Some _plog ->
            cache.dirty_count <- Int64.succ cache.dirty_count;
            if
              Int64.(
                compare
                  (add cache.new_count cache.dirty_count)
                  cache.free_count)
              > 0
            then failwith "Out of space" );
        di )

let _get_superblock_io () =
  (* This will only work on Unix, which has buffered IO instead of direct IO.
  TODO figure out portability *)
  Cstruct.create 512

type mount_options = {
  (* Whether the empty value should be considered a tombstone,
   * meaning that `mem` will return no value when finding it *)
  has_tombstone : bool;
  (* If enabled, instead of checking the entire filesystem when opening,
   * leaf nodes won't be scanned.  They will be scanned on open instead. *)
  fast_scan : bool;
  (* How many blocks to keep in cache *)
  cache_size : int
}

(* All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  (* Size of blocks, in bytes *)
  val block_size : int

  (* The exact size of all keys, in bytes *)
  val key_size : int
end

module type PARAMS = sig
  include SUPERBLOCK_PARAMS
end

let standard_mount_options =
  {has_tombstone = false; fast_scan = true; cache_size = 1024}

module StandardSuperblockParams : SUPERBLOCK_PARAMS = struct
  let block_size = 256 * 1024

  let key_size = 20
end

type deviceOpenMode =
  | OpenExistingDevice
  | FormatEmptyDevice of int64

module type S = sig
  type key

  type value

  type disk

  type root

  module Key : sig
    include Hashtbl.HashedType with type t = key

    include Map.OrderedType with type t := key
  end

  module P : PARAMS

  val key_of_cstruct : Cstruct.t -> key

  val key_of_string : string -> key

  val key_of_string_padded : string -> key

  val cstruct_of_key : key -> Cstruct.t

  val string_of_key : key -> string

  val value_of_cstruct : Cstruct.t -> value

  val value_of_string : string -> value

  val value_equal : value -> value -> bool

  val cstruct_of_value : value -> Cstruct.t

  val string_of_value : value -> string

  val next_key : key -> key

  val is_tombstone : root -> value -> bool

  val insert : root -> key -> value -> unit Lwt.t

  val lookup : root -> key -> value option Lwt.t

  val mem : root -> key -> bool Lwt.t

  val flush : root -> int64 Lwt.t

  val fstrim : root -> int64 Lwt.t

  val live_trim : root -> int64 Lwt.t

  val log_statistics : root -> unit

  val search_range :
    root ->
    key (* start inclusive *) ->
    key (* end exclusive *) ->
    (key -> value -> unit) ->
    unit Lwt.t

  val iter : root -> (key -> value -> unit) -> unit Lwt.t

  val prepare_io :
    deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
end

let read_superblock_params (type disk)
    (module B : Mirage_types_lwt.BLOCK with type t = disk) disk =
  let block_io = _get_superblock_io () in
  let block_io_fanned = [block_io] in
  B.read disk 0L block_io_fanned
  >>= Lwt.wrap1 (function
        | Result.Error _ ->
            raise ReadError
        | Result.Ok () ->
            let sb = _sb_io block_io in
            if copy_superblock_magic sb <> superblock_magic then
              raise BadMagic
            else if get_superblock_version sb <> superblock_version then
              raise BadVersion
            else if get_superblock_incompat_flags sb <> sb_required_incompat
            then raise BadFlags
            else if not @@ Wodan_crc32c.cstruct_valid sb then
              raise @@ BadCRC 0L
            else
              let block_size = Int32.to_int @@ get_superblock_block_size sb in
              let key_size = get_superblock_key_size sb in
              ( module struct
                let block_size = block_size

                let key_size = key_size
              end
              : SUPERBLOCK_PARAMS ) )

module Make (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) : S with type disk = B.t =
struct
  type key = string

  type value = string

  type disk = B.t

  module P = P

  module Key = struct
    include String

    let hash = Hashtbl.hash
  end

  let key_of_cstruct key =
    if Cstruct.len key <> P.key_size then
      raise @@ BadKey (Cstruct.to_string key)
    else Cstruct.to_string key

  let key_of_string key =
    if String.length key <> P.key_size then raise @@ BadKey key else key

  let key_of_string_padded key =
    if String.length key > P.key_size then raise @@ BadKey key
    else key ^ String.make (P.key_size - String.length key) '\000'

  let cstruct_of_key key = Cstruct.of_string key

  let string_of_key key = key

  let value_of_string value =
    let len = String.length value in
    if len >= 65536 then raise @@ ValueTooLarge value else value

  let value_of_cstruct value = value_of_string @@ Cstruct.to_string value

  let value_equal = String.equal

  let cstruct_of_value value = Cstruct.of_string value

  let string_of_value value = value

  let block_end = P.block_size - sizeof_crc

  let _get_block_io () =
    if P.block_size >= Io_page.page_size then
      Io_page.get_buf ~n:(P.block_size / Io_page.page_size) ()
    else
      (* This will only work on Unix, which has buffered IO instead of direct IO.
            Allows more efficient fuzzing. *)
      Cstruct.create P.block_size

  let zero_key = String.make P.key_size '\000'

  let top_key = String.make P.key_size '\255'

  let zero_data = Cstruct.create P.block_size

  let _is_zero_data cstr = Cstruct.equal cstr zero_data

  let childlink_size = P.key_size + sizeof_logical

  let next_key key =
    if key = top_key then invalid_arg "Already at top key";
    let r = Bytes.make P.key_size '\000' in
    let state = ref 1 in
    for i = P.key_size - 1 downto 0 do
      let code = (!state + Char.code key.[i]) mod 256 in
      Bytes.set r i @@ Char.chr code;
      state := if code = 0 then 1 else 0
    done;
    Bytes.to_string r

  type filesystem = {
    (* Backing device *)
    disk : B.t;
    (* The exact size of IO the BLOCK accepts.
     * Even larger powers of two won't work *)
    (* 4096 with unbuffered target=unix, 512 with virtualisation *)
    sector_size : int;
    (* the sector size that's used for read/write offsets *)
    other_sector_size : int;
    mount_options : mount_options
  }

  type open_fs = {
    filesystem : filesystem;
    node_cache : node_cache
  }

  type root = {
    open_fs : open_fs;
    root_key : LRUKey.t
  }

  let is_tombstone root value =
    root.open_fs.filesystem.mount_options.has_tombstone
    && String.length value = 0

  let _load_data_at filesystem logical =
    Logs.debug (fun m -> m "_load_data_at %Ld" logical);
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list filesystem.sector_size cstr in
    B.read filesystem.disk
      Int64.(
        div (mul logical @@ of_int P.block_size)
        @@ of_int filesystem.other_sector_size)
      io_data
    >>= Lwt.wrap1 (function
          | Result.Error _ ->
              raise ReadError
          | Result.Ok () ->
              if not @@ Wodan_crc32c.cstruct_valid cstr then
                raise @@ BadCRC logical
              else (cstr, io_data) )

  let _find_childlinks_offset cstr value_end =
    let rec scan off poff =
      if off < value_end then poff
      else
        let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
        if log1 <> 0L then scan (off - childlink_size) off else poff
    in
    scan (block_end - childlink_size) block_end

  (* build a logdata_index *)
  let _index_logdata cstr hdrsize =
    let value_count = Int32.to_int @@ get_anynode_hdr_value_count cstr in
    Logs.debug (fun m -> m "_index_logdata value_count:%d" value_count);
    let r =
      { logdata_contents = KeyedMap.create ();
        value_end = hdrsize;
        old_value_end = 0 }
    in
    let rec scan off value_count =
      if value_count <= 0 then ()
      else
        let key = Cstruct.to_string @@ Cstruct.sub cstr off P.key_size in
        let len = Cstruct.LE.get_uint16 cstr (off + P.key_size) in
        let va =
          Cstruct.to_string
          @@ Cstruct.sub cstr (off + P.key_size + sizeof_datalen) len
        in
        KeyedMap.xadd key va r.logdata_contents;
        r.value_end <- off + P.key_size + sizeof_datalen + len;
        scan r.value_end @@ pred value_count
    in
    scan hdrsize value_count;
    r.old_value_end <- r.value_end;
    r

  let rec _gen_childlink_offsets start =
    if start >= block_end then []
    else start :: (_gen_childlink_offsets @@ (start + childlink_size))

  let _compute_children entry =
    Logs.debug (fun m -> m "_compute_children");
    let r = KeyedMap.create () in
    List.iter
      (fun off ->
        let key =
          Cstruct.to_string @@ Cstruct.sub entry.raw_node off P.key_size
        in
        KeyedMap.xadd key (Int64.of_int off) r )
      (_gen_childlink_offsets entry.childlinks.childlinks_offset);
    r

  let _load_root_node_at open_fs logical =
    Logs.debug (fun m -> m "_load_root_node_at");
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
    let cached_node, logdata =
      match get_anynode_hdr_nodetype cstr with
      | 1 ->
          (`Root, _index_logdata cstr sizeof_rootnode_hdr)
      | ty ->
          raise @@ BadNodeType ty
    in
    let alloc_id = next_alloc_id cache in
    let rdepth = get_rootnode_hdr_depth cstr in
    let rec entry =
      { parent_key = None;
        cached_node;
        raw_node = cstr;
        rdepth;
        io_data;
        logdata;
        flush_info = None;
        children = lazy (_compute_children entry);
        children_alloc_ids = KeyedMap.create ();
        highest_key = top_key;
        prev_logical = Some logical;
        childlinks =
          {childlinks_offset = _find_childlinks_offset cstr logdata.value_end}
      }
    in
    lru_xset cache.lru alloc_id entry;
    Lwt.return (alloc_id, entry)

  let _load_child_node_at open_fs logical highest_key parent_key rdepth =
    Logs.debug (fun m -> m "_load_child_node_at");
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
    let cached_node, logdata =
      match get_anynode_hdr_nodetype cstr with
      | 2 ->
          (`Child, _index_logdata cstr sizeof_childnode_hdr)
      | ty ->
          raise @@ BadNodeType ty
    in
    let alloc_id = next_alloc_id cache in
    let rec entry =
      { parent_key = Some parent_key;
        cached_node;
        raw_node = cstr;
        rdepth;
        io_data;
        logdata;
        flush_info = None;
        children = lazy (_compute_children entry);
        children_alloc_ids = KeyedMap.create ();
        highest_key;
        prev_logical = Some logical;
        childlinks =
          {childlinks_offset = _find_childlinks_offset cstr logdata.value_end}
      }
    in
    lru_xset cache.lru alloc_id entry;
    Lwt.return entry

  let _has_children entry = entry.childlinks.childlinks_offset <> block_end

  let has_free_space entry space =
    match space with
    | InsSpaceChild size ->
        let refsize =
          entry.childlinks.childlinks_offset - (P.block_size / 2)
        in
        refsize >= size
    | InsSpaceValue size ->
        let refsize =
          if _has_children entry then
            (P.block_size / 2) - entry.logdata.value_end
          else block_end - entry.logdata.value_end
        in
        refsize >= size

  let _write_node open_fs alloc_id =
    let cache = open_fs.node_cache in
    match lru_get cache.lru alloc_id with
    | None ->
        failwith "missing lru entry in _write_node"
    | Some entry -> (
        let gen = next_generation open_fs.node_cache in
        set_anynode_hdr_generation entry.raw_node gen;
        set_anynode_hdr_value_count entry.raw_node
        @@ Int32.of_int
        @@ KeyedMap.length entry.logdata.logdata_contents;
        let logical = next_logical_alloc_valid cache in
        Logs.debug (fun m ->
            m "_write_node logical:%Ld gen:%Ld vlen:%d value_end:%d" logical
              gen
              (KeyedMap.length entry.logdata.logdata_contents)
              entry.logdata.value_end );
        ( match lookup_parent_link cache.lru entry with
        | Some (parent_key, parent_entry, offset) ->
            assert (parent_key <> alloc_id);
            Cstruct.LE.set_uint64 parent_entry.raw_node
              (Int64.to_int offset + P.key_size)
              logical
        | None ->
            () );
        ( if entry.rdepth = 0l then
          match cache.scan_map with
          | None ->
              ()
          | Some scan_map ->
              bitv_set64 scan_map logical true );
        let offset = ref @@ header_size entry.cached_node in
        (* XXX Writes in sorted order *)
        KeyedMap.iter
          (fun key va ->
            let len = String.length va in
            let len1 = len + P.key_size + sizeof_datalen in
            Cstruct.blit_from_string key 0 entry.raw_node !offset P.key_size;
            Cstruct.LE.set_uint16 entry.raw_node (!offset + P.key_size) len;
            Cstruct.blit_from_string va 0 entry.raw_node
              (!offset + P.key_size + sizeof_datalen)
              len;
            offset := !offset + len1 )
          entry.logdata.logdata_contents;
        ( if entry.logdata.value_end < entry.logdata.old_value_end then
          let len = entry.logdata.old_value_end - entry.logdata.value_end in
          Cstruct.blit (Cstruct.create len) 0 entry.raw_node
            entry.logdata.value_end len );
        (entry.logdata).old_value_end <- entry.logdata.value_end;
        Wodan_crc32c.cstruct_reset entry.raw_node;
        ( match entry.prev_logical with
        | Some plog ->
            Logs.debug (fun m -> m "Decreasing dirty_count");
            cache.dirty_count <- int64_pred_nowrap cache.dirty_count;
            bitv_set64 cache.space_map plog false;
            cache.freed_intervals
            <- BlockIntervals.add
                 (BlockIntervals.Interval.make plog plog)
                 cache.freed_intervals
        | None ->
            Logs.debug (fun m -> m "Decreasing free_count");
            cache.free_count <- int64_pred_nowrap cache.free_count;
            Logs.debug (fun m ->
                m "Decreasing new_count from %Ld" cache.new_count );
            cache.new_count <- int64_pred_nowrap cache.new_count
            (* XXX BUG sometimes wraps *) );
        bitv_set64 cache.space_map logical true;
        cache.freed_intervals
        <- BlockIntervals.remove
             (BlockIntervals.Interval.make logical logical)
             cache.freed_intervals;
        entry.prev_logical <- Some logical;
        B.write open_fs.filesystem.disk
          Int64.(
            div (mul logical @@ of_int P.block_size)
            @@ of_int open_fs.filesystem.other_sector_size)
          entry.io_data
        >>= function
        | Result.Ok () ->
            Lwt.return ()
        | Result.Error _ ->
            Lwt.fail WriteError )

  let _log_statistics cache =
    let stats = cache.statistics in
    Logs.info (fun m ->
        m "Ops: %d inserts %d lookups" stats.inserts stats.lookups );
    let logical_size = bitv_len64 cache.space_map in
    (* Don't count the superblock as a node *)
    Logs.debug (fun m -> m "Decreasing free_count to log stats");
    let nstored =
      int64_pred_nowrap @@ Int64.sub logical_size cache.free_count
    in
    let ndirty = cache.dirty_count in
    let nnew = cache.new_count in
    Logs.info (fun m ->
        m "Nodes: %Ld on-disk (%Ld dirty), %Ld new" nstored ndirty nnew );
    Logs.info (fun m -> m "LRU: %d" (LRU.items cache.lru));
    ()

  let log_statistics root =
    let cache = root.open_fs.node_cache in
    _log_statistics cache

  let flush root =
    let open_fs = root.open_fs in
    let cache = open_fs.node_cache in
    Logs.info (fun m ->
        m "Flushing %d dirty roots"
          ( match cache.flush_root with
          | None ->
              0
          | Some _ ->
              1 ) );
    _log_statistics cache;
    if
      Int64.(
        compare cache.free_count @@ add cache.new_count cache.dirty_count)
      < 0
    then failwith "Out of space";
    let rec flush_rec parent_key _key alloc_id
        (completion_list : unit Lwt.t list) =
      if alloc_id = parent_key then (
        Logs.err (fun m ->
            m "Reference loop in flush_children at %Ld" alloc_id );
        failwith "Reference loop" );
      match lru_get cache.lru alloc_id with
      | None ->
          failwith "missing alloc_id"
      | Some entry -> (
          Logs.debug (fun m ->
              m "collecting %Ld parent %Ld" alloc_id parent_key );
          match entry.flush_info with
          (* Can happen with a diamond pattern *)
          | None ->
              failwith "Flushed but missing flush_info"
          | Some di ->
              let completion_list =
                KeyedMap.fold (flush_rec alloc_id) di.flush_children
                  completion_list
              in
              entry.flush_info <- None;
              _write_node open_fs alloc_id :: completion_list )
    in
    let r =
      Lwt.join
        ( match cache.flush_root with
        | None ->
            []
        | Some alloc_id ->
            flush_rec 0L zero_key alloc_id [] )
    in
    cache.flush_root <- None;
    assert (cache.new_count = 0L);
    assert (cache.dirty_count = 0L);
    r >>= fun () -> Lwt.return @@ Int64.pred cache.next_generation

  let _discard_block_range open_fs logical n =
    B.discard open_fs.filesystem.disk
      Int64.(
        div (mul logical @@ of_int P.block_size)
        @@ of_int open_fs.filesystem.other_sector_size)
      Int64.(
        div (mul n @@ of_int P.block_size)
        @@ of_int open_fs.filesystem.other_sector_size)
    >|= function
    | res ->
        Rresult.R.get_ok res

  let fstrim root =
    let open_fs = root.open_fs in
    let cache = open_fs.node_cache in
    let discard_count = ref 0L in
    let unused_start = ref None in
    let to_discard = ref [] in
    Bitv.iteri
      (fun i used ->
        match (!unused_start, used) with
        | None, false ->
            unused_start := Some i
        | Some start, true ->
            let range_block_count = Int64.of_int @@ (i - start) in
            to_discard := (start, range_block_count) :: !to_discard;
            discard_count := Int64.add !discard_count range_block_count;
            unused_start := None
        | _ ->
            () )
      cache.space_map;
    ( match !unused_start with
    | Some start ->
        let range_block_count =
          Int64.sub cache.logical_size @@ Int64.of_int start
        in
        to_discard := (start, range_block_count) :: !to_discard
    | _ ->
        () );
    Lwt_list.iter_s
      (fun (start, range_block_count) ->
        _discard_block_range open_fs (Int64.of_int start) range_block_count )
      !to_discard
    >|= fun () -> !discard_count

  (* Discard blocks that have been unused since mounting
   or since the last live_trim call *)
  let live_trim root =
    let discard_count = ref 0L in
    let to_discard = ref [] in
    BlockIntervals.iter
      (fun iv ->
        let start = BlockIntervals.Interval.x iv in
        let exclend = Int64.succ @@ BlockIntervals.Interval.y iv in
        let range_block_count = Int64.sub exclend start in
        discard_count := Int64.add !discard_count range_block_count;
        to_discard := (start, range_block_count) :: !to_discard )
      root.open_fs.node_cache.freed_intervals;
    Lwt_list.iter_s
      (fun (start, range_block_count) ->
        _discard_block_range root.open_fs start range_block_count )
      !to_discard
    >|= fun () -> !discard_count

  let _new_node open_fs tycode parent_key highest_key rdepth =
    let cache = open_fs.node_cache in
    let alloc_id = next_alloc_id cache in
    Logs.debug (fun m -> m "_new_node type:%d alloc_id:%Ld" tycode alloc_id);
    let cstr = _get_block_io () in
    assert (Cstruct.len cstr = P.block_size);
    set_anynode_hdr_nodetype cstr tycode;
    set_anynode_hdr_fsid cache.fsid 0 cstr;
    let io_data = make_fanned_io_list open_fs.filesystem.sector_size cstr in
    let cached_node =
      match tycode with
      | 1 ->
          `Root
      | 2 ->
          `Child
      | ty ->
          raise @@ BadNodeType ty
    in
    let value_end = header_size cached_node in
    let logdata =
      { logdata_contents = KeyedMap.create ();
        value_end;
        old_value_end = value_end }
    in
    let entry =
      { parent_key;
        cached_node;
        raw_node = cstr;
        rdepth;
        io_data;
        logdata;
        flush_info = None;
        children = Lazy.from_val @@ KeyedMap.create ();
        children_alloc_ids = KeyedMap.create ();
        highest_key;
        prev_logical = None;
        childlinks = {childlinks_offset = block_end} }
    in
    lru_xset cache.lru alloc_id entry;
    (alloc_id, entry)

  let _new_root open_fs = _new_node open_fs 1 None top_key 0l

  let _reset_contents entry =
    let hdrsize = header_size entry.cached_node in
    (entry.logdata).value_end <- hdrsize;
    (entry.logdata).old_value_end <- hdrsize;
    (entry.logdata).logdata_contents <- KeyedMap.create ();
    (entry.childlinks).childlinks_offset <- block_end;
    entry.children <- Lazy.from_val (KeyedMap.create ());
    entry.children_alloc_ids <- KeyedMap.create ();
    Cstruct.blit zero_data 0 entry.raw_node hdrsize (block_end - hdrsize)

  let _add_child parent child alloc_id cache parent_key =
    Logs.debug (fun m -> m "_add_child");
    let child_key = alloc_id in
    let off = parent.childlinks.childlinks_offset - childlink_size in
    let children = Lazy.force parent.children in
    (* Force *before* blitting *)
    child.parent_key <- Some parent_key;
    Cstruct.blit
      (Cstruct.of_string child.highest_key)
      0 parent.raw_node off P.key_size;
    (parent.childlinks).childlinks_offset <- off;
    KeyedMap.xadd
      (Cstruct.to_string @@ Cstruct.sub parent.raw_node off P.key_size)
      (Int64.of_int off) children;
    KeyedMap.xadd
      (Cstruct.to_string @@ Cstruct.sub parent.raw_node off P.key_size)
      alloc_id parent.children_alloc_ids;
    (*ignore @@ _mark_dirty cache parent_key;*)
    ignore @@ _mark_dirty cache child_key

  let _has_logdata entry =
    entry.logdata.value_end <> header_size entry.cached_node

  let _update_space_map cache logical expect_sm =
    let sm = bitv_get64 cache.space_map logical in
    if sm <> expect_sm then
      if expect_sm then failwith "logical address appeared out of thin air"
      else failwith "logical address referenced twice";
    if not expect_sm then (
      bitv_set64 cache.space_map logical true;
      cache.free_count <- int64_pred_nowrap cache.free_count )

  let rec _scan_all_nodes open_fs logical expect_root rdepth parent_gen
      expect_sm =
    Logs.debug (fun m -> m "_scan_all_nodes %Ld %ld" logical rdepth);
    (* TODO add more fsck style checks *)
    let cache = open_fs.node_cache in
    _update_space_map cache logical expect_sm;
    let%lwt cstr, _io_data = _load_data_at open_fs.filesystem logical in
    let hdrsize =
      match get_anynode_hdr_nodetype cstr with
      | 1
      (* root *)
        when expect_root ->
          sizeof_rootnode_hdr
      | 2
      (* inner *)
        when not expect_root ->
          sizeof_childnode_hdr
      | ty ->
          raise @@ BadNodeType ty
    in
    let fsid = Cstruct.to_string @@ get_anynode_hdr_fsid cstr in
    if fsid <> cache.fsid then raise (BadNodeFSID fsid);
    let gen = get_anynode_hdr_generation cstr in
    (* prevents cycles *)
    if gen >= parent_gen then
      failwith "generation is not lower than for parent";
    let value_count = Int32.to_int @@ get_anynode_hdr_value_count cstr in
    let rec scan_kd off value_count =
      if value_count <= 0 then off
      else
        let off1 = off + P.key_size + sizeof_datalen in
        if off1 > block_end then failwith "data bleeding past end of node";
        (* TODO check for key unicity in scan_kd and scan_cl *)
        let _key = Cstruct.to_string @@ Cstruct.sub cstr off P.key_size in
        let len = Cstruct.LE.get_uint16 cstr (off + P.key_size) in
        let len1 = len + P.key_size + sizeof_datalen in
        let off2 = off + len1 in
        if off2 > block_end then failwith "data bleeding past end of node";
        scan_kd off2 @@ pred value_count
    in
    let value_end = scan_kd hdrsize value_count in
    let rec scan_cl off =
      if off < hdrsize then
        failwith "child link data bleeding into start of node";
      if off >= value_end then
        let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
        if log1 <> 0L then (
          (* Children here would mean the fast_scan free space map is borked *)
          if rdepth = 0l then failwith "Found children on a leaf node";
          ( if rdepth = 1l && open_fs.filesystem.mount_options.fast_scan then (
            _update_space_map cache log1 false;
            Lwt.return_unit )
          else
            _scan_all_nodes open_fs log1 false (Int32.pred rdepth) gen false
          )
          >>= fun () -> scan_cl (off - childlink_size) )
        else Lwt.return_unit
      else Lwt.return_unit
    in
    scan_cl (block_end - childlink_size)
    >>= fun () ->
    ( if rdepth = 0l then
      match cache.scan_map with
      | None ->
          ()
      | Some scan_map ->
          bitv_set64 scan_map logical true );
    Lwt.return_unit

  let _logical_of_offset cstr offset =
    Cstruct.LE.get_uint64 cstr (Int64.to_int offset + P.key_size)

  let _preload_child open_fs entry_key entry child_key offset =
    (*Logs.debug (fun m -> m "_preload_child");*)
    let cstr = entry.raw_node in
    let cache = open_fs.node_cache in
    if entry.rdepth = 0l then
      failwith "invalid rdepth: found children when rdepth = 0";
    let rdepth = Int32.pred entry.rdepth in
    match KeyedMap.find_opt child_key entry.children_alloc_ids with
    | None ->
        let logical = _logical_of_offset cstr offset in
        ( if%lwt Lwt.return open_fs.filesystem.mount_options.fast_scan then
          match cache.scan_map with
          | None ->
              assert false
          | Some scan_map ->
              if%lwt
                Lwt.return
                  (rdepth = 0l && (not @@ bitv_get64 scan_map logical))
              then
                (* generation may not be fresh, but is always initialised in this branch,
               so this is not a problem *)
                let parent_gen = get_anynode_hdr_generation cstr in
                _scan_all_nodes open_fs logical false rdepth parent_gen true
        )
        >>= fun () ->
        let%lwt child_entry =
          _load_child_node_at open_fs logical child_key entry_key rdepth
        in
        let alloc_id = next_alloc_id cache in
        KeyedMap.xadd child_key alloc_id entry.children_alloc_ids;
        lru_xset cache.lru alloc_id child_entry;
        Lwt.return (alloc_id, child_entry)
    | Some alloc_id -> (
      match lru_get cache.lru alloc_id with
      | None ->
          Lwt.fail
          @@ Failure
               (Printf.sprintf "Missing LRU entry for loaded child %Ld %Ld"
                  offset alloc_id)
      | Some child_entry ->
          Lwt.return (alloc_id, child_entry) )

  let _ins_req_space = function
    | InsValue value ->
        let len = String.length value in
        let len1 = P.key_size + sizeof_datalen + len in
        InsSpaceValue len1
    | InsChild (_loc, _alloc_id) ->
        InsSpaceChild (P.key_size + sizeof_logical)

  let _fast_insert fs alloc_id key insertable _depth =
    (*Logs.debug (fun m -> m "_fast_insert %Ld" _depth);*)
    match lru_get fs.node_cache.lru alloc_id with
    | None ->
        failwith
        @@ Printf.sprintf "Missing LRU entry for %Ld (_fast_insert)" alloc_id
    | Some entry -> (
        assert (String.compare key entry.highest_key <= 0);
        assert (has_free_space entry @@ _ins_req_space insertable);
        (* Simple insertion *)
        match insertable with
        | InsValue value ->
            let len = String.length value in
            let len1 = P.key_size + sizeof_datalen + len in
            let kd = entry.logdata in
            (* TODO optionally optimize storing tombstones on leaf nodes *)
            KeyedMap.map1 key
              (function
                | None ->
                    (* Padded length *)
                    kd.value_end <- kd.value_end + len1;
                    Some value
                | Some prev_val ->
                    (* No need to pad lengths *)
                    kd.value_end
                    <- kd.value_end - String.length prev_val + len;
                    Some value)
              kd.logdata_contents;
            ignore @@ _mark_dirty fs.node_cache alloc_id
        | InsChild (loc, child_alloc_id_opt) ->
            let cstr = entry.raw_node in
            let cls = entry.childlinks in
            let offset = cls.childlinks_offset - childlink_size in
            let children = Lazy.force entry.children in
            cls.childlinks_offset <- offset;
            Cstruct.blit (Cstruct.of_string key) 0 cstr offset P.key_size;
            Cstruct.LE.set_uint64 cstr (offset + P.key_size) loc;
            KeyedMap.xadd
              (Cstruct.to_string @@ Cstruct.sub cstr offset P.key_size)
              (Int64.of_int offset) children;
            ( match child_alloc_id_opt with
            | None ->
                ()
            | Some child_alloc_id ->
                KeyedMap.xadd
                  (Cstruct.to_string @@ Cstruct.sub cstr offset P.key_size)
                  child_alloc_id entry.children_alloc_ids );
            ignore @@ _mark_dirty fs.node_cache alloc_id )

  let _split_point entry =
    if _has_children entry then
      let children = Lazy.force entry.children in
      let n = KeyedMap.length children in
      let binds = keyedmap_keys children in
      let median = List.nth binds @@ (n / 2) in
      median
    else
      let kdc = entry.logdata.logdata_contents in
      let n = KeyedMap.length kdc in
      let binds = keyedmap_keys kdc in
      let median = List.nth binds @@ (n / 2) in
      median

  let rec _check_live_integrity fs alloc_id depth =
    let fail = ref false in
    match lru_peek fs.node_cache.lru alloc_id with
    | None ->
        failwith "Missing LRU entry"
    | Some entry ->
        ( if
            _has_children entry
            && not
                 ( String.equal entry.highest_key
                 @@ fst
                 @@ unwrap_opt
                 @@ KeyedMap.max_binding
                 @@ Lazy.force entry.children )
          then (
            string_dump @@ entry.highest_key;
            string_dump
            @@ fst
            @@ unwrap_opt
            @@ KeyedMap.max_binding
            @@ Lazy.force entry.children;
            Logs.err (fun m ->
                m "_check_live_integrity %Ld invariant broken: highest_key"
                  depth );
            fail := true );
          match entry.parent_key with
          | None ->
              ()
          | Some parent_key -> (
            match lru_peek fs.node_cache.lru parent_key with
            | None ->
                failwith "Missing parent"
            | Some parent_entry -> (
                let children = Lazy.force parent_entry.children in
                match KeyedMap.find_opt entry.highest_key children with
                | None ->
                    Logs.err (fun m ->
                        m
                          "_check_live_integrity %Ld invariant broken: \
                           lookup_parent_link"
                          depth );
                    fail := true
                | Some _offset ->
                    assert (
                      KeyedMap.find_opt entry.highest_key
                        parent_entry.children_alloc_ids
                      = Some alloc_id ) ) ) );
        let vend = ref @@ header_size entry.cached_node in
        KeyedMap.iter
          (fun _k va ->
            vend := !vend + P.key_size + sizeof_datalen + String.length va )
          entry.logdata.logdata_contents;
        if !vend != entry.logdata.value_end then (
          Logs.err (fun m -> m "Inconsistent value_end %Ld" depth);
          fail := true );
        ( match entry.flush_info with
        | Some flush_info -> (
            if
              KeyedMap.exists
                (fun _k child_alloc_id -> child_alloc_id = alloc_id)
                flush_info.flush_children
            then (
              Logs.err (fun m -> m "Self-pointing flush reference %Ld" depth);
              fail := true );
            match entry.parent_key with
            | None ->
                ()
            | Some parent_key -> (
              match lru_peek fs.node_cache.lru parent_key with
              | None ->
                  failwith "Missing parent"
              | Some parent_entry -> (
                match parent_entry.flush_info with
                | None ->
                    failwith "Missing parent_entry.flush_info"
                | Some di ->
                    let n =
                      KeyedMap.fold
                        (fun _k el acc ->
                          if el = alloc_id then succ acc else acc )
                        di.flush_children 0
                    in
                    if n = 0 then (
                      Logs.err (fun m ->
                          m
                            "Dirty but not registered in \
                             parent_entry.flush_info %Ld %Ld"
                            depth alloc_id );
                      fail := true )
                    else if n > 1 then (
                      Logs.err (fun m ->
                          m
                            "Dirty, registered %d times in \
                             parent_entry.flush_info %Ld"
                            n depth );
                      fail := true ) ) ) )
        | None -> (
          match entry.parent_key with
          | None ->
              ()
          | Some parent_key -> (
            match lru_peek fs.node_cache.lru parent_key with
            | None ->
                failwith "Missing parent"
            | Some parent_entry -> (
              match parent_entry.flush_info with
              | None ->
                  ()
              | Some di ->
                  if
                    KeyedMap.exists
                      (fun _k el -> el = alloc_id)
                      di.flush_children
                  then (
                    Logs.err (fun m ->
                        m
                          "Not dirty but registered in \
                           parent_entry.flush_info %Ld"
                          depth );
                    fail := true ) ) ) ) );
        KeyedMap.iter (fun k offset ->
            let cstr = entry.raw_node in
            let key =
              Cstruct.to_string
              @@ Cstruct.sub cstr (Int64.to_int offset) P.key_size
            in
            assert (k = key) )
        @@ Lazy.force entry.children;
        KeyedMap.iter
          (fun _k child_alloc_id ->
            if child_alloc_id = alloc_id then (
              Logs.err (fun m -> m "Self-pointing node %Ld" depth);
              fail := true )
            else _check_live_integrity fs child_alloc_id @@ Int64.succ depth
            )
          entry.children_alloc_ids;
        if !fail then failwith "Integrity errors"

  let _check_live_integrity _fs _alloc_id _depth = ()

  let _fixup_parent_links cache alloc_id entry =
    KeyedMap.iter
      (fun _k child_alloc_id ->
        match lru_peek cache.lru child_alloc_id with
        | None ->
            failwith "Missing LRU entry"
        | Some centry ->
            centry.parent_key <- Some alloc_id )
      entry.children_alloc_ids

  let _value_at fs va =
    let len = String.length va in
    if fs.mount_options.has_tombstone && len = 0 then None else Some va

  let _is_value fs va =
    if not fs.mount_options.has_tombstone then true
    else
      let len = String.length va in
      len <> 0

  (* lwt because it might load from disk *)
  let rec _reserve_insert fs alloc_id space split_path depth =
    (*Logs.debug (fun m -> m "_reserve_insert %Ld" depth);*)
    _check_live_integrity fs alloc_id depth;
    match lru_get fs.node_cache.lru alloc_id with
    | None ->
        failwith
        @@ Printf.sprintf "Missing LRU entry for %Ld (insert)" alloc_id
    | Some entry -> (
        if has_free_space entry space then (
          _reserve_dirty fs.node_cache alloc_id 0L depth;
          Lwt.return () )
        else if (not split_path) && _has_children entry && _has_logdata entry
        then (
          (* log spilling *)
          let children = Lazy.force entry.children in
          let find_victim () =
            let spill_score = ref 0 in
            let best_spill_score = ref 0 in
            (* an iterator on entry.children keys would be helpful here *)
            let scored_key =
              ref @@ fst @@ unwrap_opt @@ KeyedMap.min_binding children
            in
            let best_spill_key = ref !scored_key in
            KeyedMap.iter
              (fun k va ->
                if String.compare k !scored_key > 0 then (
                  if !spill_score > !best_spill_score then (
                    best_spill_score := !spill_score;
                    best_spill_key := !scored_key );
                  spill_score := 0;
                  match KeyedMap.find_first_opt k children with
                  | None ->
                      string_dump k;
                      string_dump
                      @@ fst
                      @@ unwrap_opt
                      @@ KeyedMap.max_binding children;
                      string_dump entry.highest_key;
                      failwith "children invariant broken"
                  | Some (sk, _cl) ->
                      scored_key := sk );
                let len = String.length va in
                let len1 = P.key_size + sizeof_datalen + len in
                spill_score := !spill_score + len1 )
              entry.logdata.logdata_contents;
            if !spill_score > !best_spill_score then (
              best_spill_score := !spill_score;
              best_spill_key := !scored_key );
            (!best_spill_score, !best_spill_key)
          in
          let best_spill_score, best_spill_key = find_victim () in
          Logs.debug (fun m ->
              m "log spilling %Ld %Ld %d" depth alloc_id best_spill_score );
          let offset = keyedmap_find best_spill_key children in
          let%lwt child_alloc_id, _ce =
            _preload_child fs alloc_id entry best_spill_key offset
          in
          let clo = entry.childlinks.childlinks_offset in
          let nko = entry.logdata.value_end in
          (*Logs.debug (fun m -> m "Before _reserve_insert nko %d" entry.logdata.value_end);*)
          _reserve_insert fs child_alloc_id (InsSpaceValue best_spill_score)
            false
          @@ Int64.succ depth
          >>= fun () ->
          (*Logs.debug (fun m -> m "After _reserve_insert nko %d" entry.logdata.value_end);*)
          if
            clo = entry.childlinks.childlinks_offset
            && nko = entry.logdata.value_end
          then (
            (* _reserve_insert didn't split the child or the root *)
            _reserve_dirty fs.node_cache child_alloc_id 0L @@ Int64.succ depth;
            let before_bsk_succ =
              match KeyedMap.find_last_opt best_spill_key children with
              | Some (before_bsk, _va) ->
                  next_key before_bsk
              | None ->
                  zero_key
            in
            (* which keys we will dispatch *)
            let carved_map =
              KeyedMap.carve_inclusive_range before_bsk_succ best_spill_key
                entry.logdata.logdata_contents
            in
            (entry.logdata).value_end
            <- entry.logdata.value_end - best_spill_score;
            KeyedMap.iter
              (fun key va ->
                _fast_insert fs child_alloc_id key (InsValue va)
                @@ Int64.succ depth )
              carved_map );
          _reserve_insert fs alloc_id space split_path depth )
        else
          match entry.parent_key with
          | None ->
              (* Node splitting (root) *)
              assert (depth = 0L);
              Logs.debug (fun m -> m "node splitting %Ld %Ld" depth alloc_id);
              let kc = entry.logdata.logdata_contents in
              let children = Lazy.force entry.children in
              _reserve_dirty fs.node_cache alloc_id 2L depth;
              let di = _mark_dirty fs.node_cache alloc_id in
              let median = _split_point entry in
              let alloc1, entry1 =
                _new_node fs 2 (Some alloc_id) median entry.rdepth
              in
              let alloc2, entry2 =
                _new_node fs 2 (Some alloc_id) entry.highest_key entry.rdepth
              in
              let kc2 = KeyedMap.split_off_after median kc in
              let cl2 = KeyedMap.split_off_after median children in
              let ca2 =
                KeyedMap.split_off_after median entry.children_alloc_ids
              in
              let fc2 = KeyedMap.split_off_after median di.flush_children in
              let blit_cd_child k offset centry =
                let cstr0 = entry.raw_node in
                let cstr1 = centry.raw_node in
                let offset1 =
                  centry.childlinks.childlinks_offset - childlink_size
                in
                (centry.childlinks).childlinks_offset <- offset1;
                Cstruct.blit cstr0 (Int64.to_int offset) cstr1 offset1
                  childlink_size;
                assert (Lazy.is_val centry.children);
                let key1 =
                  Cstruct.to_string @@ Cstruct.sub cstr1 offset1 P.key_size
                in
                Logs.debug (fun m ->
                    m "Blitting %S (%S) from offset %Ld" key1 k offset );
                assert (k = key1);
                KeyedMap.xadd key1 (Int64.of_int offset1)
                  (Lazy.force centry.children)
              in
              KeyedMap.iter
                (fun _k va ->
                  (entry1.logdata).value_end
                  <- entry1.logdata.value_end
                     + String.length va
                     + P.key_size
                     + sizeof_datalen )
                kc;
              KeyedMap.iter
                (fun _k va ->
                  (entry2.logdata).value_end
                  <- entry2.logdata.value_end
                     + String.length va
                     + P.key_size
                     + sizeof_datalen )
                kc2;
              KeyedMap.iter (fun k off -> blit_cd_child k off entry1) children;
              KeyedMap.iter (fun k off -> blit_cd_child k off entry2) cl2;
              KeyedMap.swap entry1.logdata.logdata_contents kc;
              KeyedMap.swap entry2.logdata.logdata_contents kc2;
              entry1.children_alloc_ids <- entry.children_alloc_ids;
              entry2.children_alloc_ids <- ca2;
              _reset_contents entry;
              entry.rdepth <- Int32.succ entry.rdepth;
              set_rootnode_hdr_depth entry.raw_node entry.rdepth;
              entry.flush_info <- Some {flush_children = KeyedMap.create ()};
              _fixup_parent_links fs.node_cache alloc1 entry1;
              _fixup_parent_links fs.node_cache alloc2 entry2;
              _add_child entry entry1 alloc1 fs.node_cache alloc_id;
              _add_child entry entry2 alloc2 fs.node_cache alloc_id;
              entry1.flush_info <- Some {flush_children = di.flush_children};
              entry2.flush_info <- Some {flush_children = fc2};
              Lwt.return_unit
          | Some parent_key -> (
              (* Node splitting (non root) *)
              assert (Int64.compare depth 0L > 0);
              Logs.debug (fun m -> m "node splitting %Ld %Ld" depth alloc_id);
              (* Set split_path to prevent spill/split recursion; will split towards the root *)
              _reserve_insert fs parent_key (InsSpaceChild childlink_size)
                true
              @@ Int64.pred depth
              >>= fun () ->
              let _children = Lazy.force entry.children in
              _reserve_dirty fs.node_cache alloc_id 1L depth;
              let di = _mark_dirty fs.node_cache alloc_id in
              let median = _split_point entry in
              let alloc1, entry1 =
                _new_node fs 2 (Some parent_key) median entry.rdepth
              in
              let to_remove = ref [] in
              let remove_size = ref 0 in
              let kc1 =
                KeyedMap.split_off_after median entry.logdata.logdata_contents
              in
              KeyedMap.swap kc1 entry.logdata.logdata_contents;
              KeyedMap.iter
                (fun key va ->
                  let len = String.length va in
                  let len1 = len + P.key_size + sizeof_datalen in
                  _fast_insert fs alloc1 key (InsValue va) depth;
                  remove_size := !remove_size + len1;
                  to_remove := key :: !to_remove )
                kc1;
              List.iter
                (fun key -> KeyedMap.remove key entry.logdata.logdata_contents)
                !to_remove;
              (entry.logdata).value_end
              <- entry.logdata.value_end - !remove_size;
              let clo_out = ref block_end in
              let clo_out1 = ref block_end in
              let clo = ref @@ (block_end - childlink_size) in
              let children = Lazy.force entry.children in
              let children1 = KeyedMap.create () in
              let fc1 = KeyedMap.create () in
              while !clo >= entry.childlinks.childlinks_offset do
                (* Move children data *)
                let key1 =
                  Cstruct.to_string
                  @@ Cstruct.sub entry.raw_node !clo P.key_size
                in
                if String.compare key1 median <= 0 then (
                  clo_out1 := !clo_out1 - childlink_size;
                  Cstruct.blit entry.raw_node !clo entry1.raw_node !clo_out1
                    childlink_size;
                  ( match KeyedMap.find_opt key1 entry.children_alloc_ids with
                  | Some alloc_id ->
                      KeyedMap.remove key1 entry.children_alloc_ids;
                      KeyedMap.xadd key1 alloc_id entry1.children_alloc_ids
                  | None ->
                      () );
                  KeyedMap.remove key1 children;
                  KeyedMap.xadd key1 (Int64.of_int !clo_out1) children1;
                  if KeyedMap.mem key1 di.flush_children then (
                    let child_alloc_id =
                      keyedmap_find key1 di.flush_children
                    in
                    KeyedMap.remove key1 di.flush_children;
                    KeyedMap.xadd key1 child_alloc_id fc1 ) )
                else (
                  clo_out := !clo_out - childlink_size;
                  Cstruct.blit entry.raw_node !clo entry.raw_node !clo_out
                    childlink_size;
                  let key1 =
                    Cstruct.to_string
                    @@ Cstruct.sub entry.raw_node !clo_out P.key_size
                  in
                  KeyedMap.update key1 (Int64.of_int !clo_out) children )
              done;
              (entry.childlinks).childlinks_offset <- !clo_out;
              (entry1.childlinks).childlinks_offset <- !clo_out1;
              entry1.children <- Lazy.from_val children1;
              _fixup_parent_links fs.node_cache alloc1 entry1;
              (* Hook new node into parent *)
              match lru_peek fs.node_cache.lru parent_key with
              | None ->
                  failwith
                  @@ Printf.sprintf "Missing LRU entry for %Ld (parent)"
                       alloc_id
              | Some parent ->
                  ( _add_child parent entry1 alloc1 fs.node_cache parent_key;
                    entry1.flush_info <- Some {flush_children = fc1};
                    match parent.flush_info with
                    | None ->
                        failwith "Missing flush_info for parent"
                    | Some di ->
                        KeyedMap.add median alloc1 di.flush_children );
                  _reserve_insert fs alloc_id space split_path depth ) )

  let insert root key value =
    (*Logs.debug (fun m -> m "insert");*)
    let stats = root.open_fs.node_cache.statistics in
    stats.inserts <- succ stats.inserts;
    _check_live_integrity root.open_fs root.root_key 0L;
    _reserve_insert root.open_fs root.root_key
      (_ins_req_space @@ InsValue value)
      false 0L
    >>= fun () ->
    _check_live_integrity root.open_fs root.root_key 0L;
    _fast_insert root.open_fs root.root_key key (InsValue value) 0L;
    _check_live_integrity root.open_fs root.root_key 0L;
    Lwt.return ()

  let rec _lookup open_fs alloc_id key =
    Logs.debug (fun m -> m "_lookup");
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        Logs.err (fun m -> m "Missing LRU entry for %Ld (lookup)" alloc_id);
        failwith
        @@ Printf.sprintf "Missing LRU entry for %Ld (lookup)" alloc_id
    | Some entry -> (
      match KeyedMap.find_opt key entry.logdata.logdata_contents with
      | Some va ->
          (*Logs.debug (fun m -> m "Found");*)
          if _is_value open_fs.filesystem va then Lwt.return_some va
          else Lwt.return_none
      | None ->
          if not @@ _has_children entry then Lwt.return_none
          else
            let key1, offset =
              unwrap_opt
              @@ KeyedMap.find_first_opt key
              @@ Lazy.force entry.children
            in
            let%lwt child_alloc_id, _ce =
              _preload_child open_fs alloc_id entry key1 offset
            in
            _lookup open_fs child_alloc_id key )

  let rec _mem open_fs alloc_id key =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        failwith @@ Printf.sprintf "Missing LRU entry for %Ld (mem)" alloc_id
    | Some entry -> (
      match KeyedMap.find_opt key entry.logdata.logdata_contents with
      | Some va ->
          Lwt.return @@ _is_value open_fs.filesystem va
      | None ->
          Logs.debug (fun m -> m "_mem");
          if not @@ _has_children entry then Lwt.return_false
          else
            let key1, offset =
              unwrap_opt
              @@ KeyedMap.find_first_opt key
              @@ Lazy.force entry.children
            in
            let%lwt child_alloc_id, _ce =
              _preload_child open_fs alloc_id entry key1 offset
            in
            _mem open_fs child_alloc_id key )

  let lookup root key =
    let stats = root.open_fs.node_cache.statistics in
    stats.lookups <- succ stats.lookups;
    _lookup root.open_fs root.root_key key

  let mem root key =
    let stats = root.open_fs.node_cache.statistics in
    stats.lookups <- succ stats.lookups;
    _mem root.open_fs root.root_key key

  let rec _search_range open_fs alloc_id start end_ seen callback =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        failwith
        @@ Printf.sprintf "Missing LRU entry for %Ld (search_range)" alloc_id
    | Some entry ->
        let seen1 = ref seen in
        let lwt_queue = ref [] in
        (* The range from start inclusive to end_ exclusive *)
        KeyedMap.iter_range start end_
          (fun k va ->
            ( match _value_at open_fs.filesystem va with
            | Some v ->
                callback k v
            | None ->
                () );
            seen1 := KeyedSet.add k !seen1 )
          entry.logdata.logdata_contents;
        (* As above, but end at end_ inclusive *)
        KeyedMap.iter_inclusive_range start end_ (fun key1 offset ->
            lwt_queue := (key1, offset) :: !lwt_queue )
        @@ Lazy.force entry.children;
        Lwt_list.iter_s
          (fun (key1, offset) ->
            let%lwt child_alloc_id, _ce =
              _preload_child open_fs alloc_id entry key1 offset
            in
            _search_range open_fs child_alloc_id start end_ !seen1 callback )
          !lwt_queue

  (* The range from start inclusive to end_ exclusive
     Results are in no particular order. *)
  let search_range root start end_ callback =
    let seen = KeyedSet.empty in
    let stats = root.open_fs.node_cache.statistics in
    stats.range_searches <- succ stats.range_searches;
    _search_range root.open_fs root.root_key start end_ seen callback

  let rec _iter open_fs alloc_id callback =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        failwith @@ Printf.sprintf "Missing LRU entry for %Ld (iter)" alloc_id
    | Some entry ->
        let lwt_queue = ref [] in
        KeyedMap.iter
          (fun k va ->
            match _value_at open_fs.filesystem va with
            | Some v ->
                callback k v
            | None ->
                () )
          entry.logdata.logdata_contents;
        KeyedMap.iter (fun key1 offset ->
            lwt_queue := (key1, offset) :: !lwt_queue )
        @@ Lazy.force entry.children;
        Lwt_list.iter_s
          (fun (key1, offset) ->
            let%lwt child_alloc_id, _ce =
              _preload_child open_fs alloc_id entry key1 offset
            in
            _iter open_fs child_alloc_id callback )
          !lwt_queue

  let iter root callback =
    let stats = root.open_fs.node_cache.statistics in
    stats.iters <- succ stats.iters;
    _iter root.open_fs root.root_key callback

  let _read_superblock fs =
    let block_io = _get_superblock_io () in
    let block_io_fanned = make_fanned_io_list fs.sector_size block_io in
    B.read fs.disk 0L block_io_fanned
    >>= Lwt.wrap1 (function
          | Result.Error _ ->
              raise ReadError
          | Result.Ok () ->
              let sb = _sb_io block_io in
              if copy_superblock_magic sb <> superblock_magic then
                raise BadMagic
              else if get_superblock_version sb <> superblock_version then
                raise BadVersion
              else if get_superblock_incompat_flags sb <> sb_required_incompat
              then raise BadFlags
              else if not @@ Wodan_crc32c.cstruct_valid sb then
                raise @@ BadCRC 0L
              else if
                get_superblock_block_size sb <> Int32.of_int P.block_size
              then (
                Logs.err (fun m ->
                    m "Bad superblock size %ld %d"
                      (get_superblock_block_size sb)
                      P.block_size );
                raise BadParams )
              else if get_superblock_key_size sb <> P.key_size then
                raise BadParams
              else
                ( get_superblock_first_block_written sb,
                  get_superblock_logical_size sb,
                  Cstruct.to_string @@ get_superblock_fsid sb ) )

  (* Requires the caller to discard the entire device first.
     Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let _format open_fs logical_size first_block_written fsid =
    let block_io = _get_superblock_io () in
    let block_io_fanned =
      make_fanned_io_list open_fs.filesystem.sector_size block_io
    in
    let alloc_id, _root = _new_root open_fs in
    (open_fs.node_cache).new_count <- 1L;
    _write_node open_fs alloc_id
    >>= fun () ->
    _log_statistics open_fs.node_cache;
    let sb = _sb_io block_io in
    set_superblock_magic superblock_magic 0 sb;
    set_superblock_version sb superblock_version;
    set_superblock_incompat_flags sb sb_required_incompat;
    set_superblock_block_size sb (Int32.of_int P.block_size);
    set_superblock_key_size sb P.key_size;
    set_superblock_first_block_written sb first_block_written;
    set_superblock_logical_size sb logical_size;
    set_superblock_fsid fsid 0 sb;
    Wodan_crc32c.cstruct_reset sb;
    B.write open_fs.filesystem.disk 0L block_io_fanned
    >>= function
    | Result.Ok () ->
        Lwt.return ()
    | Result.Error _ ->
        Lwt.fail WriteError

  let _mid_range start end_ lsize =
    (* might overflow, limit lsize *)
    (* if start = end_, we pick the farthest logical address *)
    if Int64.(succ start) = end_ || (Int64.(succ start) = lsize && end_ = 1L)
    then None
    else
      let end_ =
        if Int64.compare start end_ < 0 then end_ else Int64.(add end_ lsize)
      in
      let mid = Int64.(shift_right_logical (add start end_) 1) in
      let mid = Int64.(rem mid lsize) in
      let mid = if mid = 0L then 1L else mid in
      Some mid

  let _scan_for_root fs start0 lsize fsid =
    Logs.debug (fun m -> m "_scan_for_root");
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list fs.sector_size cstr in
    let read logical =
      B.read fs.disk
        Int64.(
          div (mul logical @@ of_int P.block_size)
          @@ of_int fs.other_sector_size)
        io_data
      >>= function
      | Result.Error _ ->
          Lwt.fail ReadError
      | Result.Ok () ->
          Lwt.return ()
    in
    let next_logical logical =
      let log1 = Int64.succ logical in
      if log1 = lsize then 1L else log1
    in
    let is_valid_root () =
      get_anynode_hdr_nodetype cstr = 1
      && Cstruct.to_string @@ get_anynode_hdr_fsid cstr = fsid
      && Wodan_crc32c.cstruct_valid cstr
    in
    let rec _scan_range start end_opt =
      if Some start = end_opt then
        Lwt.fail @@ Failure "Didn't find a valid root"
      else
        let end_opt = if end_opt = None then Some start else end_opt in
        read start
        >>= fun () ->
        if is_valid_root () then
          Lwt.return (start, get_anynode_hdr_generation cstr)
        else _scan_range (next_logical start) end_opt
    in
    let rec sfr_rec start0 end0 gen0 =
      (* end/start swapped on purpose *)
      match _mid_range end0 start0 lsize with
      | None ->
          Lwt.return end0
      | Some start1 ->
          let%lwt end1, gen1 = _scan_range start1 None in
          if gen0 < gen1 then sfr_rec start0 end1 gen1
          else sfr_rec start1 end0 gen0
    in
    let%lwt end0, gen0 = _scan_range start0 None in
    sfr_rec start0 end0 gen0

  let prepare_io mode disk mount_options =
    B.get_info disk
    >>= fun info ->
    Logs.debug (fun m -> m "prepare_io sector_size %d" info.sector_size);
    let sector_size = if false then info.sector_size else 512 in
    let block_size = P.block_size in
    let io_size =
      if block_size >= Io_page.page_size then Io_page.page_size
      else block_size
    in
    assert (block_size >= io_size);
    assert (io_size >= sector_size);
    assert (block_size mod io_size = 0);
    assert (io_size mod sector_size = 0);
    let fs =
      {disk; sector_size; other_sector_size = info.sector_size; mount_options}
    in
    match mode with
    | OpenExistingDevice ->
        let%lwt fbw, logical_size, fsid = _read_superblock fs in
        let%lwt lroot = _scan_for_root fs fbw logical_size fsid in
        let%lwt cstr, _io_data = _load_data_at fs lroot in
        let typ = get_anynode_hdr_nodetype cstr in
        if typ <> 1 then raise @@ BadNodeType typ;
        let root_generation = get_rootnode_hdr_generation cstr in
        let rdepth = get_rootnode_hdr_depth cstr in
        let space_map = bitv_create64 logical_size false in
        Bitv.set space_map 0 true;
        let scan_map =
          if mount_options.fast_scan then
            Some (bitv_create64 logical_size false)
          else None
        in
        let freed_intervals = BlockIntervals.empty in
        let free_count = Int64.pred logical_size in
        let node_cache =
          { lru = lru_create mount_options.cache_size;
            flush_root = None;
            next_alloc_id = 1L;
            next_generation = Int64.succ root_generation;
            logical_size;
            space_map;
            scan_map;
            freed_intervals;
            free_count;
            new_count = 0L;
            dirty_count = 0L;
            fsid;
            next_logical_alloc = lroot;
            (* in use, but that's okay *)
            statistics = default_statistics }
        in
        let open_fs = {filesystem = fs; node_cache} in
        (* TODO add more integrity checking *)
        _scan_all_nodes open_fs lroot true rdepth Int64.max_int false
        >>= fun () ->
        let%lwt root_key, _entry = _load_root_node_at open_fs lroot in
        let root = {open_fs; root_key} in
        log_statistics root;
        Lwt.return (root, root_generation)
    | FormatEmptyDevice logical_size ->
        assert (logical_size >= 2L);
        let space_map = bitv_create64 logical_size false in
        Bitv.set space_map 0 true;
        let freed_intervals = BlockIntervals.empty in
        let free_count = Int64.pred logical_size in
        let first_block_written = Nocrypto.Rng.Int64.gen_r 1L logical_size in
        let fsid = Cstruct.to_string @@ Nocrypto.Rng.generate 16 in
        let node_cache =
          { lru = lru_create mount_options.cache_size;
            flush_root = None;
            next_alloc_id = 1L;
            next_generation = 1L;
            logical_size;
            space_map;
            scan_map = None;
            freed_intervals;
            free_count;
            new_count = 0L;
            dirty_count = 0L;
            fsid;
            next_logical_alloc = first_block_written;
            statistics = default_statistics }
        in
        let open_fs = {filesystem = fs; node_cache} in
        _format open_fs logical_size first_block_written fsid
        >>= fun () ->
        let root_key = 1L in
        Lwt.return ({open_fs; root_key}, 1L)
end

type open_ret =
  | OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

let open_for_reading (type disk) (module B : EXTBLOCK with type t = disk) disk
    mount_options =
  read_superblock_params (module B) disk
  >>= function
  | sp -> (
      let module Stor = Make (B) ((val sp)) in
      Stor.prepare_io OpenExistingDevice disk mount_options
      >>= function
      | root, gen ->
          Lwt.return (OPEN_RET ((module Stor), root, gen)) )
