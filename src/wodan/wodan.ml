(********************************************************************************)
(*  Copyright 2017-2019 Gabriel de Perthuis <g2p.code@gmail.com>                *)
(*                                                                              *)
(*  Permission to use, copy, modify, and/or distribute this software for any    *)
(*  purpose with or without fee is hereby granted, provided that the above      *)
(*  copyright notice and this permission notice appear in all copies.           *)
(*                                                                              *)
(*  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES    *)
(*  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF            *)
(*  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR     *)
(*  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES      *)
(*  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN       *)
(*  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR  *)
(*  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.                 *)
(*                                                                              *)
(********************************************************************************)

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

exception UnableToSplit

exception LRUCantDiscardDirty

exception LRUTooSmall

exception LRUPriorityInversion

exception BadKey of string

exception ValueTooLarge of string

exception BadNodeType of int

exception BadNodeFSID of string

exception MissingLRUEntry of int64

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK

  val discard : t -> int64 -> int64 -> (unit, write_error) result io
end

module BlockCompat (B : Mirage_types_lwt.BLOCK) : EXTBLOCK with type t = B.t =
struct
  include B

  let discard _ _ _ = Lwt.return (Ok ())
end

(* Incompatibility flags *)
let sb_incompat_rdepth = 1l

let sb_incompat_fsid = 2l

let sb_incompat_value_count = 4l

let sb_required_incompat =
  Int32.logor sb_incompat_rdepth
    (Int32.logor sb_incompat_fsid sb_incompat_value_count)

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

let sb_io block_io = Cstruct.sub block_io 0 sizeof_superblock

let string_dump key = Cstruct.hexdump (Cstruct.of_string key)

let src = Logs.Src.create "wodan" ~doc:"logs Wodan operations"

module Logs = (val Logs.src_log src : Logs.LOG)

module BlockIntervals = Diet.Make (struct
  include Int64

  let t_of_sexp = int64_of_sexp

  let sexp_of_t = sexp_of_int64
end)

module KeyedMap = Keyedmap.Make (String)
module KeyedSet = Set.Make (String)

module LRUKey = struct
  type t = int64

  let hash = Hashtbl.hash

  let equal = Int64.equal
end

type logdata_index = {
  contents : string KeyedMap.t;
  mutable value_end : int
}

type node_meta =
  | Root
  | Child of (* parent key *) LRUKey.t

let header_size = function
  | Root ->
      sizeof_rootnode_hdr
  | Child _ ->
      sizeof_childnode_hdr

let is_root = function
  | Root ->
      true
  | _ ->
      false

let nodetype = function
  | Root ->
      1
  | Child _ ->
      2

type node = {
  mutable meta : node_meta;
  (* A node is flushable iff it's referenced from flush_root
     through a flush_children map.
     We use an option here to make checking for flushability faster.
     A flushable node is either new or dirty, but not both. *)
  mutable flush_children : int64 KeyedMap.t option;
  (* Use offsets so that data isn't duplicated *)
  mutable children : int64 KeyedMap.t;
  (* Don't reference nodes directly, always go through the
   * LRU to bump recently accessed nodes *)
  mutable children_alloc_ids : int64 KeyedMap.t;
  mutable highest_key : string;
  logdata : logdata_index;
  mutable prev_logical : int64 option;
  (* depth counted from the leaves; mutable on the root only *)
  mutable rdepth : int32;
  mutable generation : int64
}

module LRUValue = struct
  type t = node

  let weight _val = 1
end

module LRU = Lru.M.Make (LRUKey) (LRUValue)

let lru_get lru alloc_id = LRU.find alloc_id lru

let lru_peek lru alloc_id = LRU.find ~promote:false alloc_id lru

exception AlreadyCached of LRUKey.t

let lookup_parent_link lru entry =
  match entry.meta with
  | Root ->
      None
  | Child parent_key -> (
    match lru_peek lru parent_key with
    | None ->
        raise (MissingLRUEntry parent_key)
    | Some parent_entry ->
        Some (parent_key, parent_entry) )

let lru_reserve lru weight =
  (* May raise LRUCantDiscardDirty *)
  if weight > LRU.capacity lru then
    raise LRUTooSmall;
  while LRU.size lru + weight > LRU.capacity lru do
    (match LRU.lru lru with
    | Some (_alloc_id, entry)
      when entry.flush_children <> None ->
        raise LRUCantDiscardDirty
    | Some (_alloc_id, entry)
      when not (KeyedMap.is_empty entry.children_alloc_ids) ->
        raise LRUPriorityInversion
    | Some (_alloc_id, entry) -> (
      match lookup_parent_link lru entry with
      | None ->
        (* If it would discard the root, despite it being bumped on every traversal,
           that means the LRU capacity is too small for the tree depth.
           Raise LRUTooSmall instead of an LRUCantDiscardRoot *)
          raise LRUTooSmall
      | Some (_parent_key, parent_entry) ->
          KeyedMap.remove parent_entry.children_alloc_ids entry.highest_key )
    | None (* The LRU doesn't have room for the single element we want to add.
              Since we have asserted that weight <= capacity, this should be unreachable.
              Raise an exception that's not meant to be caught. *) ->
        failwith "LRU capacity is too small" );
    LRU.drop_lru lru
  done

let lru_fast_xset lru alloc_id value =
  if LRU.mem alloc_id lru then raise (AlreadyCached alloc_id);
  if LRUValue.weight value > LRU.capacity lru then
    raise LRUTooSmall;
  if LRU.size lru + LRUValue.weight value > LRU.capacity lru
  then failwith "lru_fast_xset outside fast path (would discard)";
  LRU.add alloc_id value lru

let lru_create capacity = LRU.create capacity

type node_cache = {
  (* LRUKey.t -> node
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
  space_map : Bitv64.t;
  scan_map : Bitv64.t option;
  mutable freed_intervals : BlockIntervals.t;
  statistics : Statistics.t
}

let has_scan_map cache =
  match cache.scan_map with
  | None ->
      false
  | Some _ ->
      true

let next_logical_novalid cache logical =
  let log1 = Int64.succ logical in
  if log1 = cache.logical_size then 1L else log1

let next_logical_alloc_valid cache =
  if cache.free_count = 0L then failwith "Out of space";
  (* Not the same as OutOfSpace *)
  let rec after log =
    if not (Bitv64.get cache.space_map log) then log
    else after (next_logical_novalid cache log)
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

(* Merge two sorted lists into one *)
let rec merge xs ys =
   match xs, ys with
   | [], _ -> ys
   | _, [] -> xs
   | hx :: txs, hy :: tys ->
       if hx < hy then hx :: merge txs ys else hy :: merge xs tys

type insertable =
  | InsValue of string
  | InsChild of int64 * int64 option

(* loc, alloc_id *)

(*|InsTombstone*)
(* use empty values for now *)

type insert_space =
  | InsSpaceValue of int
  | InsSpaceChild of int

let rec reserve_dirty_rec cache alloc_id new_count dirty_count =
  (*Logs.debug (fun m -> m "reserve_dirty_rec %Ld" alloc_id);*)
  match lru_get cache.lru alloc_id with
  | None ->
      raise (MissingLRUEntry alloc_id)
  | Some entry -> (
    match entry.flush_children with
    | Some _di ->
        ()
    | None -> (
        ( match entry.meta with
        | Root ->
            ()
        | Child parent_key -> (
          match lru_get cache.lru parent_key with
          | None ->
              failwith "missing parent_entry"
          | Some _parent_entry ->
              reserve_dirty_rec cache parent_key new_count dirty_count ) );
        match entry.prev_logical with
        | None ->
            new_count := Int64.succ !new_count
        | Some _plog ->
            dirty_count := Int64.succ !dirty_count ) )

let reserve_dirty cache alloc_id new_count depth =
  (*Logs.debug (fun m -> m "reserve_dirty %Ld" alloc_id);*)
  let new_count = ref new_count in
  let dirty_count = ref 0L in
  reserve_dirty_rec cache alloc_id new_count dirty_count;
  (*Logs.debug (fun m -> m "reserve_dirty %Ld free %Ld allocs N %Ld D %Ld counter N %Ld D %Ld depth %Ld"
             alloc_id cache.free_count cache.new_count cache.dirty_count !new_count !dirty_count depth);*)
  if
    Int64.(
      compare cache.free_count
        (add cache.dirty_count
           (add !dirty_count (add cache.new_count !new_count))))
    < 0
  then
    if
      Int64.(
        compare cache.free_count
          (add !dirty_count
             (add cache.new_count (add !new_count (succ depth)))))
      >= 0
    then raise NeedsFlush (* flush and retry, it will succeed *)
    else raise OutOfSpace

(* flush if you like, but retrying will not succeed *)

let rec mark_dirty cache alloc_id =
  (*Logs.debug (fun m -> m "mark_dirty %Ld" alloc_id);*)
  match lru_get cache.lru alloc_id with
  | None ->
      raise (MissingLRUEntry alloc_id)
  | Some entry -> (
    match entry.flush_children with
    | Some di ->
        di
    | None ->
        ( match entry.meta with
        | Root -> (
          match cache.flush_root with
          | None ->
              cache.flush_root <- Some alloc_id
          | _ ->
              failwith "flush_root inconsistent" )
        | Child parent_key -> (
          match lru_get cache.lru parent_key with
          | None ->
              failwith "missing parent_entry"
          | Some _parent_entry ->
              let parent_di = mark_dirty cache parent_key in
              if KeyedMap.exists (fun _k lk -> lk = alloc_id) parent_di then
                failwith "dirty_node inconsistent"
              else KeyedMap.add parent_di entry.highest_key alloc_id ) );
        let di = KeyedMap.create () in
        entry.flush_children <- Some di;
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

let get_superblock_io () =
  (* This will only work on Unix, which has buffered IO instead of direct IO.
  TODO figure out portability *)
  Cstruct.create 512

type relax = {
  (* CRC errors ignored on any read where the magic CRC is used *)
  magic_crc : bool;
  (* Write non-superblock blocks with the magic CRC *)
  magic_crc_write : bool
}

type mount_options = {
  (* Whether the empty value should be considered a tombstone,
   * meaning that `mem` will return no value when finding it *)
  has_tombstone : bool;
  (* If enabled, instead of checking the entire filesystem when opening,
   * leaf nodes won't be scanned.  They will be scanned on open instead. *)
  fast_scan : bool;
  (* How many blocks to keep in cache *)
  cache_size : int;
  (* Integrity invariants to relax *)
  relax : relax
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
  {has_tombstone = false; fast_scan = true; cache_size = 1024; relax = {
       magic_crc = false; magic_crc_write = false } }

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

let magic_crc = Cstruct.of_string "\xff\xff\xff\xff"

let has_magic_crc cstr =
  let crcoffset = Cstruct.len cstr - 4 in
  let crc = Cstruct.sub cstr crcoffset 4 in
  (* Don't use Cstruct.equal, it will use memcmp, be opaque to AFL *)
  (*Cstruct.equal crc magic_crc*)
  Cstruct.get_uint8 crc 0 = Cstruct.get_uint8 magic_crc 0 &&
  Cstruct.get_uint8 crc 1 = Cstruct.get_uint8 magic_crc 1 &&
  Cstruct.get_uint8 crc 2 = Cstruct.get_uint8 magic_crc 2 &&
  Cstruct.get_uint8 crc 3 = Cstruct.get_uint8 magic_crc 3

let cstruct_valid cstr relax =
  (relax.magic_crc && has_magic_crc cstr) || Crc32c.cstruct_valid cstr

let cstruct_reset cstr relax =
  if relax.magic_crc_write then
    let crcoffset = Cstruct.len cstr - 4 in
    Cstruct.blit magic_crc 0 cstr crcoffset 4
  else Crc32c.cstruct_reset cstr

let read_superblock_params (type disk)
    (module B : Mirage_types_lwt.BLOCK with type t = disk) disk relax =
  let block_io = get_superblock_io () in
  let block_io_fanned = [block_io] in
  B.read disk 0L block_io_fanned
  >>= Lwt.wrap1 (function
        | Result.Error _ ->
            raise ReadError
        | Result.Ok () ->
            let sb = sb_io block_io in
            if copy_superblock_magic sb <> superblock_magic then
              raise BadMagic
            else if get_superblock_version sb <> superblock_version then
              raise BadVersion
            else if get_superblock_incompat_flags sb <> sb_required_incompat
            then raise BadFlags
            else if not (cstruct_valid sb relax) then raise (BadCRC 0L)
            else
              let block_size = Int32.to_int (get_superblock_block_size sb) in
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
      raise (BadKey (Cstruct.to_string key))
    else Cstruct.to_string key

  let key_of_string key =
    if String.length key <> P.key_size then raise (BadKey key) else key

  let key_of_string_padded key =
    if String.length key > P.key_size then raise (BadKey key)
    else key ^ String.make (P.key_size - String.length key) '\000'

  let cstruct_of_key key = Cstruct.of_string key

  let string_of_key key = key

  let value_of_string value =
    let len = String.length value in
    if len >= 65536 then raise (ValueTooLarge value) else value

  let value_of_cstruct value = value_of_string (Cstruct.to_string value)

  let value_equal = String.equal

  let cstruct_of_value value = Cstruct.of_string value

  let string_of_value value = value

  let block_end = P.block_size - sizeof_crc

  let get_block_io () =
    if P.block_size >= Io_page.page_size then
      Io_page.get_buf ~n:(P.block_size / Io_page.page_size) ()
    else
      (* This will only work on Unix, which has buffered IO instead of direct IO.
            Allows more efficient fuzzing. *)
      Cstruct.create P.block_size

  let zero_key = String.make P.key_size '\000'

  let top_key = String.make P.key_size '\255'

  let childlink_size = P.key_size + sizeof_logical

  (* TODO Fuzz this (was buggy) *)
  let next_key key =
    if key = top_key then invalid_arg "Already at top key";
    let r = Bytes.make P.key_size '\000' in
    let state = ref 1 in
    for i = P.key_size - 1 downto 0 do
      let code = (!state + Char.code key.[i]) mod 256 in
      Bytes.set r i (Char.chr code);
      state := if !state <> 0 && code = 0 then 1 else 0
    done;
    Bytes.to_string r

  type filesystem = {
    (* Backing device *)
    disk : B.t;
    (* The exact size of IO the BLOCK accepts.
       Even larger powers of two won't work *)
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

  let load_data_at filesystem logical =
    Logs.debug (fun m -> m "load_data_at %Ld" logical);
    let cstr = get_block_io () in
    let io_data = make_fanned_io_list filesystem.sector_size cstr in
    B.read filesystem.disk
      Int64.(
        div
          (mul logical (of_int P.block_size))
          (of_int filesystem.other_sector_size))
      io_data
    >>= Lwt.wrap1 (function
          | Result.Error _ ->
              raise ReadError
          | Result.Ok () ->
              if not (cstruct_valid cstr filesystem.mount_options.relax) then raise (BadCRC logical)
              else cstr )

  let find_childlinks_offset cstr value_end =
    let rec scan off poff =
      if off < value_end then poff
      else
        let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
        if log1 <> 0L then scan (off - childlink_size) off else poff
    in
    scan (block_end - childlink_size) block_end

  (* build a logdata_index *)
  let index_logdata cstr hdrsize =
    let value_count = Int32.to_int (get_anynode_hdr_value_count cstr) in
    Logs.debug (fun m -> m "index_logdata value_count:%d" value_count);
    let r = {contents = KeyedMap.create (); value_end = hdrsize} in
    let rec scan off value_count =
      if value_count <= 0 then ()
      else
        let key = Cstruct.to_string (Cstruct.sub cstr off P.key_size) in
        let len = Cstruct.LE.get_uint16 cstr (off + P.key_size) in
        let va =
          Cstruct.to_string
            (Cstruct.sub cstr (off + P.key_size + sizeof_datalen) len)
        in
        KeyedMap.xadd r.contents key va;
        r.value_end <- off + P.key_size + sizeof_datalen + len;
        scan r.value_end (pred value_count)
    in
    scan hdrsize value_count; r

  let rec gen_childlink_offsets start =
    if start >= block_end then []
    else start :: gen_childlink_offsets (start + childlink_size)

  let compute_children raw_node value_end =
    Logs.debug (fun m -> m "compute_children");
    let childlinks_offset = find_childlinks_offset raw_node value_end in
    let r = KeyedMap.create () in
    List.iter
      (fun off ->
        let key = Cstruct.to_string (Cstruct.sub raw_node off P.key_size) in
        KeyedMap.xadd r key (Int64.of_int off) )
      (gen_childlink_offsets childlinks_offset);
    r

  let load_root_node_at open_fs logical =
    Logs.debug (fun m -> m "load_root_node_at");
    let%lwt cstr = load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
    let meta, logdata =
      match get_anynode_hdr_nodetype cstr with
      | 1 ->
          (Root, index_logdata cstr sizeof_rootnode_hdr)
      | ty ->
          raise (BadNodeType ty)
    in
    let alloc_id = next_alloc_id cache in
    let rdepth = get_rootnode_hdr_depth cstr in
    let entry =
      { meta;
        rdepth;
        logdata;
        flush_children = None;
        children = compute_children cstr logdata.value_end;
        children_alloc_ids = KeyedMap.create ();
        highest_key = top_key;
        generation = get_anynode_hdr_generation cstr;
        prev_logical = Some logical }
    in
    lru_fast_xset cache.lru alloc_id entry;
    Lwt.return (alloc_id, entry)

  let load_child_node_at open_fs logical highest_key parent_key rdepth =
    Logs.debug (fun m -> m "load_child_node_at");
    let%lwt cstr = load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
    let meta, logdata =
      match get_anynode_hdr_nodetype cstr with
      | 2 ->
          (Child parent_key, index_logdata cstr sizeof_childnode_hdr)
      | ty ->
          raise (BadNodeType ty)
    in
    let alloc_id = next_alloc_id cache in
    let entry =
      { meta;
        rdepth;
        logdata;
        flush_children = None;
        children = compute_children cstr logdata.value_end;
        children_alloc_ids = KeyedMap.create ();
        highest_key;
        generation = get_anynode_hdr_generation cstr;
        prev_logical = Some logical }
    in
    lru_fast_xset cache.lru alloc_id entry;
    Lwt.return (alloc_id, entry)

  let has_children entry = not (KeyedMap.is_empty entry.children)

  let has_free_space entry space =
    match space with
    | InsSpaceChild size ->
        let refsize =
          P.block_size
          - sizeof_crc
          - (childlink_size * KeyedMap.length entry.children)
          - (P.block_size / 2)
        in
        refsize >= size
    | InsSpaceValue size ->
        let refsize =
          if has_children entry then
            (P.block_size / 2) - entry.logdata.value_end
          else block_end - entry.logdata.value_end
        in
        refsize >= size

  let write_node open_fs alloc_id =
    let cache = open_fs.node_cache in
    match lru_get cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry -> (
        let gen = next_generation open_fs.node_cache in
        entry.generation <- gen;
        let raw_node = get_block_io () in
        let io_data =
          make_fanned_io_list open_fs.filesystem.sector_size raw_node
        in
        set_anynode_hdr_nodetype raw_node (nodetype entry.meta);
        set_anynode_hdr_generation raw_node gen;
        set_anynode_hdr_fsid cache.fsid 0 raw_node
        (* order is strange but correct *);
        set_anynode_hdr_value_count raw_node
          (Int32.of_int (KeyedMap.length entry.logdata.contents));
        if is_root entry.meta then
          set_rootnode_hdr_depth raw_node entry.rdepth;
        let logical = next_logical_alloc_valid cache in
        Logs.debug (fun m ->
            m "write_node logical:%Ld gen:%Ld vlen:%d value_end:%d" logical
              gen
              (KeyedMap.length entry.logdata.contents)
              entry.logdata.value_end );
        ( match lookup_parent_link cache.lru entry with
        | Some (parent_key, parent_entry) ->
            assert (parent_key <> alloc_id);
            KeyedMap.replace_existing parent_entry.children entry.highest_key
              logical
        | None ->
            () );
        ( if entry.rdepth = 0l then
          match cache.scan_map with
          | None ->
              ()
          | Some scan_map ->
              Bitv64.set scan_map logical true );
        let offset = ref (header_size entry.meta) in
        (* XXX Writes in sorted order *)
        KeyedMap.iter
          (fun key va ->
            let len = String.length va in
            let len1 = len + P.key_size + sizeof_datalen in
            Cstruct.blit_from_string key 0 raw_node !offset P.key_size;
            Cstruct.LE.set_uint16 raw_node (!offset + P.key_size) len;
            Cstruct.blit_from_string va 0 raw_node
              (!offset + P.key_size + sizeof_datalen)
              len;
            offset := !offset + len1 )
          entry.logdata.contents;
        assert (!offset = entry.logdata.value_end);
        offset := block_end - childlink_size;
        KeyedMap.iter
          (fun key child_logical ->
            Cstruct.blit_from_string key 0 raw_node !offset P.key_size;
            Cstruct.LE.set_uint64 raw_node (!offset + P.key_size)
              child_logical;
            offset := !offset - childlink_size )
          entry.children;
        cstruct_reset raw_node open_fs.filesystem.mount_options.relax;
        ( match entry.prev_logical with
        | Some plog ->
            Logs.debug (fun m -> m "Decreasing dirty_count");
            cache.dirty_count <- int64_pred_nowrap cache.dirty_count;
            Bitv64.set cache.space_map plog false;
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
        Bitv64.set cache.space_map logical true;
        cache.freed_intervals
        <- BlockIntervals.remove
             (BlockIntervals.Interval.make logical logical)
             cache.freed_intervals;
        entry.prev_logical <- Some logical;
        B.write open_fs.filesystem.disk
          Int64.(
            div
              (mul logical (of_int P.block_size))
              (of_int open_fs.filesystem.other_sector_size))
          io_data
        >>= function
        | Result.Ok () ->
            Lwt.return ()
        | Result.Error _ ->
            Lwt.fail WriteError )

  let log_cache_statistics cache =
    Logs.info (fun m -> m "%a" Statistics.pp cache.statistics);
    let logical_size = Bitv64.length cache.space_map in
    (* Don't count the superblock as a node *)
    Logs.debug (fun m -> m "Decreasing free_count to log stats");
    let nstored =
      int64_pred_nowrap (Int64.sub logical_size cache.free_count)
    in
    let ndirty = cache.dirty_count in
    let nnew = cache.new_count in
    Logs.info (fun m ->
        m "Nodes: %Ld on-disk (%Ld dirty), %Ld new" nstored ndirty nnew );
    Logs.info (fun m -> m "LRU: %d" (LRU.items cache.lru));
    ()

  let log_statistics root =
    let cache = root.open_fs.node_cache in
    log_cache_statistics cache

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
    log_cache_statistics cache;
    if
      Int64.(compare cache.free_count (add cache.new_count cache.dirty_count))
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
          raise (MissingLRUEntry alloc_id)
      | Some entry -> (
          Logs.debug (fun m ->
              m "collecting %Ld parent %Ld" alloc_id parent_key );
          match entry.flush_children with
          (* Can happen with a diamond pattern *)
          | None ->
              failwith "Flushed but missing flush_info"
          | Some di ->
              let completion_list =
                KeyedMap.fold (flush_rec alloc_id) di completion_list
              in
              entry.flush_children <- None;
              write_node open_fs alloc_id :: completion_list )
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
    r >>= fun () -> Lwt.return (Int64.pred cache.next_generation)

  let discard_block_range open_fs logical n =
    B.discard open_fs.filesystem.disk
      Int64.(
        div
          (mul logical (of_int P.block_size))
          (of_int open_fs.filesystem.other_sector_size))
      Int64.(
        div
          (mul n (of_int P.block_size))
          (of_int open_fs.filesystem.other_sector_size))
    >|= function
    | res ->
        Rresult.R.get_ok res

  let fstrim root =
    let open_fs = root.open_fs in
    let cache = open_fs.node_cache in
    let discard_count = ref 0L in
    let unused_start = ref None in
    let to_discard = ref [] in
    Bitv64.iteri
      (fun i used ->
        match (!unused_start, used) with
        | None, false ->
            unused_start := Some i
        | Some start, true ->
            let range_block_count = Int64.sub i start in
            to_discard := (start, range_block_count) :: !to_discard;
            discard_count := Int64.add !discard_count range_block_count;
            unused_start := None
        | _ ->
            () )
      cache.space_map;
    ( match !unused_start with
    | Some start ->
        let range_block_count = Int64.sub cache.logical_size start in
        to_discard := (start, range_block_count) :: !to_discard
    | _ ->
        () );
    Lwt_list.iter_s
      (fun (start, range_block_count) ->
        discard_block_range open_fs start range_block_count )
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
        let exclend = Int64.succ (BlockIntervals.Interval.y iv) in
        let range_block_count = Int64.sub exclend start in
        discard_count := Int64.add !discard_count range_block_count;
        to_discard := (start, range_block_count) :: !to_discard )
      root.open_fs.node_cache.freed_intervals;
    Lwt_list.iter_s
      (fun (start, range_block_count) ->
        discard_block_range root.open_fs start range_block_count )
      !to_discard
    >|= fun () -> !discard_count

  let new_node open_fs tycode parent_key highest_key rdepth =
    let cache = open_fs.node_cache in
    let alloc_id = next_alloc_id cache in
    Logs.debug (fun m -> m "new_node type:%d alloc_id:%Ld" tycode alloc_id);
    let cstr = get_block_io () in
    assert (Cstruct.len cstr = P.block_size);
    set_anynode_hdr_nodetype cstr tycode;
    set_anynode_hdr_fsid cache.fsid 0 cstr;
    let meta =
      match (tycode, parent_key) with
      | 1, None ->
          Root
      | 2, Some parent_key ->
          Child parent_key
      | ty, _ ->
          raise (BadNodeType ty)
    in
    let value_end = header_size meta in
    let logdata = {contents = KeyedMap.create (); value_end} in
    let entry =
      { meta;
        rdepth;
        logdata;
        flush_children = None;
        children = KeyedMap.create ();
        children_alloc_ids = KeyedMap.create ();
        highest_key;
        generation = 0L;
        prev_logical = None }
    in
    lru_fast_xset cache.lru alloc_id entry;
    (alloc_id, entry)

  let new_root open_fs = new_node open_fs 1 None top_key 0l

  let reset_contents entry =
    let hdrsize = header_size entry.meta in
    entry.logdata.value_end <- hdrsize;
    KeyedMap.clear entry.logdata.contents;
    entry.children <- KeyedMap.create ();
    KeyedMap.clear entry.children_alloc_ids

  let add_child parent child child_key cache parent_key =
    Logs.debug (fun m -> m "add_child");
    child.meta <- Child parent_key;
    (* No logical yet, put 0L for now *)
    KeyedMap.xadd parent.children child.highest_key 0L;
    KeyedMap.xadd parent.children_alloc_ids child.highest_key child_key;
    ignore (mark_dirty cache child_key)

  let has_logdata entry = entry.logdata.value_end <> header_size entry.meta

  let update_space_map cache logical expect_sm =
    let sm = Bitv64.get cache.space_map logical in
    if sm <> expect_sm then
      if expect_sm then failwith "logical address appeared out of thin air"
      else failwith "logical address referenced twice";
    if not expect_sm then (
      Bitv64.set cache.space_map logical true;
      cache.free_count <- int64_pred_nowrap cache.free_count )

  let rec scan_all_nodes open_fs logical expect_root rdepth parent_gen
      expect_sm =
    Logs.debug (fun m -> m "scan_all_nodes %Ld %ld" logical rdepth);
    (* TODO add more fsck style checks *)
    let cache = open_fs.node_cache in
    update_space_map cache logical expect_sm;
    let%lwt cstr = load_data_at open_fs.filesystem logical in
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
          raise (BadNodeType ty)
    in
    let fsid = Cstruct.to_string (get_anynode_hdr_fsid cstr) in
    if fsid <> cache.fsid then raise (BadNodeFSID fsid);
    let gen = get_anynode_hdr_generation cstr in
    (* prevents cycles *)
    if gen >= parent_gen then
      failwith "generation is not lower than for parent";
    let value_count = Int32.to_int (get_anynode_hdr_value_count cstr) in
    let rec scan_kd off value_count =
      if value_count <= 0 then off
      else
        let off1 = off + P.key_size + sizeof_datalen in
        if off1 > block_end then failwith "data bleeding past end of node";
        (* TODO check for key unicity in scan_kd and scan_cl *)
        let _key = Cstruct.to_string (Cstruct.sub cstr off P.key_size) in
        let len = Cstruct.LE.get_uint16 cstr (off + P.key_size) in
        let len1 = len + P.key_size + sizeof_datalen in
        let off2 = off + len1 in
        if off2 > block_end then failwith "data bleeding past end of node";
        scan_kd off2 (pred value_count)
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
          ( if rdepth = 1l && has_scan_map cache then (
            update_space_map cache log1 false;
            Lwt.return_unit )
          else scan_all_nodes open_fs log1 false (Int32.pred rdepth) gen false
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
          Bitv64.set scan_map logical true );
    Lwt.return_unit

  let preload_child open_fs entry_key entry child_key =
    (* May raise LRUCantDiscardDirty *)
    (*Logs.debug (fun m -> m "preload_child");*)
    let cache = open_fs.node_cache in
    if entry.rdepth = 0l then
      failwith "invalid rdepth: found children when rdepth = 0";
    let rdepth = Int32.pred entry.rdepth in
    match KeyedMap.find_opt entry.children_alloc_ids child_key with
    | None ->
        lru_reserve cache.lru 1;
        let logical = KeyedMap.find entry.children child_key in
        ( if%lwt Lwt.return (has_scan_map cache) then
          match cache.scan_map with
          | None ->
              assert false
          | Some scan_map ->
              if%lwt
                Lwt.return (rdepth = 0l && not (Bitv64.get scan_map logical))
              then
                (* generation may not be fresh, but is always initialised in this branch
                 (no alloc_id -> not a new_node), so this is not a problem *)
                let parent_gen = entry.generation in
                scan_all_nodes open_fs logical false rdepth parent_gen true )
        >>= fun () ->
        let%lwt (alloc_id, child_entry) =
          load_child_node_at open_fs logical child_key entry_key rdepth
        in
        KeyedMap.xadd entry.children_alloc_ids child_key alloc_id;
        Lwt.return (alloc_id, child_entry)
    | Some alloc_id -> (
      match lru_get cache.lru alloc_id with
      | None ->
          Lwt.fail
            (Failure
               (Printf.sprintf "Missing LRU entry for loaded child %Ld"
                  alloc_id))
      | Some child_entry ->
          Lwt.return (alloc_id, child_entry) )

  let ins_req_space = function
    | InsValue value ->
        let len = String.length value in
        let len1 = P.key_size + sizeof_datalen + len in
        InsSpaceValue len1
    | InsChild (_loc, _alloc_id) ->
        InsSpaceChild (P.key_size + sizeof_logical)

  let fast_insert fs alloc_id key insertable _depth =
    (*Logs.debug (fun m -> m "fast_insert %Ld" _depth);*)
    match lru_get fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry -> (
        assert (String.compare key entry.highest_key <= 0);
        assert (has_free_space entry (ins_req_space insertable));
        (* Simple insertion *)
        match insertable with
        | InsValue value ->
            let len = String.length value in
            let len1 = P.key_size + sizeof_datalen + len in
            let kd = entry.logdata in
            (* TODO optionally optimize storing tombstones on leaf nodes *)
            KeyedMap.update kd.contents key (function
              | None ->
                  (* Padded length *)
                  kd.value_end <- kd.value_end + len1;
                  Some value
              | Some prev_val ->
                  (* No need to pad lengths *)
                  kd.value_end <- kd.value_end - String.length prev_val + len;
                  Some value );
            ignore (mark_dirty fs.node_cache alloc_id)
        | InsChild (loc, child_alloc_id_opt) ->
            KeyedMap.xadd entry.children key loc;
            ( match child_alloc_id_opt with
            | None ->
                ()
            | Some child_alloc_id ->
                KeyedMap.xadd entry.children_alloc_ids key child_alloc_id );
            ignore (mark_dirty fs.node_cache alloc_id) )

  let split_point entry =
    let child_count = KeyedMap.length entry.children in
    if child_count > 1 then
      let binds = KeyedMap.keys entry.children in
      let median = List.nth binds ((child_count - 1) / 2) in
      Some median
    else if child_count = 0 then
      let kdc = entry.logdata.contents in
      let n = KeyedMap.length kdc in
      if n = 0 then None else
      let binds = KeyedMap.keys kdc in
      let median = List.nth binds ((n - 1) / 2) in
      Some median
    else
      (* Pick a mixed median to defeat unfavourable cases *)
      (* Here child_count = 1 *)
      let kdc = entry.logdata.contents in
      let kdc_count = KeyedMap.length kdc in
      if kdc_count = 0 then
        None
      else
        let median_pos = (child_count + kdc_count - 1) / 2 in
        let mk = merge (KeyedMap.keys kdc) (KeyedMap.keys entry.children) in
        let median = List.nth mk median_pos in
        Some median

  [@@@warning "-32"]

  let rec check_live_integrity fs alloc_id depth =
    let fail = ref false in
    match lru_peek fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry ->
        ( if
            has_children entry
            && not
                 (String.equal entry.highest_key
                    (fst (KeyedMap.max_binding entry.children)))
          then (
            string_dump entry.highest_key;
            string_dump (fst (KeyedMap.max_binding entry.children));
            Logs.err (fun m ->
                m "check_live_integrity %Ld invariant broken: highest_key"
                  depth );
            fail := true );
          match entry.meta with
          | Root ->
              ()
          | Child parent_key -> (
            match lru_peek fs.node_cache.lru parent_key with
            | None ->
                raise (MissingLRUEntry parent_key)
            | Some parent_entry -> (
              match
                KeyedMap.find_opt parent_entry.children entry.highest_key
              with
              | None ->
                  Logs.err (fun m ->
                      m
                        "check_live_integrity %Ld invariant broken: \
                         lookup_parent_link"
                        depth );
                  fail := true
              | Some _offset ->
                  assert (
                    KeyedMap.find_opt parent_entry.children_alloc_ids
                      entry.highest_key
                    = Some alloc_id ) ) ) );
        let vend = ref (header_size entry.meta) in
        KeyedMap.iter
          (fun _k va ->
            vend := !vend + P.key_size + sizeof_datalen + String.length va )
          entry.logdata.contents;
        if !vend != entry.logdata.value_end then (
          Logs.err (fun m ->
              m "Inconsistent value_end depth:%Ld expected:%d actual:%d %a"
                depth !vend entry.logdata.value_end Statistics.pp
                fs.node_cache.statistics );
          fail := true );
        ( match entry.flush_children with
        | Some di -> (
            if
              KeyedMap.exists
                (fun _k child_alloc_id -> child_alloc_id = alloc_id)
                di
            then (
              Logs.err (fun m -> m "Self-pointing flush reference %Ld" depth);
              fail := true );
            match entry.meta with
            | Root ->
                ()
            | Child parent_key -> (
              match lru_peek fs.node_cache.lru parent_key with
              | None ->
                  raise (MissingLRUEntry parent_key)
              | Some parent_entry -> (
                match parent_entry.flush_children with
                | None ->
                    failwith "Missing parent_entry.flush_info"
                | Some di ->
                    let n =
                      KeyedMap.fold
                        (fun _k el acc ->
                          if el = alloc_id then succ acc else acc )
                        di 0
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
          match entry.meta with
          | Root ->
              ()
          | Child parent_key -> (
            match lru_peek fs.node_cache.lru parent_key with
            | None ->
                raise (MissingLRUEntry parent_key)
            | Some parent_entry -> (
              match parent_entry.flush_children with
              | None ->
                  ()
              | Some di ->
                  if KeyedMap.exists (fun _k el -> el = alloc_id) di then (
                    Logs.err (fun m ->
                        m
                          "Not dirty but registered in \
                           parent_entry.flush_info %Ld"
                          depth );
                    fail := true ) ) ) ) );
        KeyedMap.iter
          (fun _k child_alloc_id ->
            if child_alloc_id = alloc_id then (
              Logs.err (fun m -> m "Self-pointing node %Ld" depth);
              fail := true )
            else check_live_integrity fs child_alloc_id (Int64.succ depth) )
          entry.children_alloc_ids;
        if !fail then failwith "Integrity errors"

  [@@@warning "+32"]

  (* This is equivalent to commenting out the above, while still having it typecheck *)
  let check_live_integrity _ _ _ = ()

  let fixup_parent_links cache alloc_id entry =
    KeyedMap.iter
      (fun _k child_alloc_id ->
        match lru_peek cache.lru child_alloc_id with
        | None ->
            raise (MissingLRUEntry child_alloc_id)
        | Some centry ->
            centry.meta <- Child alloc_id )
      entry.children_alloc_ids

  let value_at fs va =
    let len = String.length va in
    if fs.mount_options.has_tombstone && len = 0 then None else Some va

  let is_value fs va =
    if not fs.mount_options.has_tombstone then true
    else
      let len = String.length va in
      len <> 0

  (* lwt because it might load from disk *)
  let rec reserve_insert fs alloc_id space split_path depth =
    (*Logs.debug (fun m -> m "reserve_insert %Ld" depth);*)
    check_live_integrity fs alloc_id depth;
    match lru_get fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry -> (
        assert (has_children entry == (entry.rdepth > 0l));
        if has_free_space entry space then (
          reserve_dirty fs.node_cache alloc_id 0L depth;
          Lwt.return () )
        else if (not split_path) && has_children entry && has_logdata entry
        then (
          (* log spilling *)
          let find_victim () =
            let spill_score = ref 0 in
            let best_spill_score = ref 0 in
            (* an iterator on entry.children keys would be helpful here *)
            let scored_key =
              ref (fst (KeyedMap.min_binding entry.children))
            in
            let best_spill_key = ref !scored_key in
            KeyedMap.iter
              (fun k va ->
                if String.compare k !scored_key > 0 then (
                  if !spill_score > !best_spill_score then (
                    best_spill_score := !spill_score;
                    best_spill_key := !scored_key );
                  spill_score := 0;
                  match KeyedMap.find_first_opt entry.children k with
                  | None ->
                      string_dump k;
                      string_dump (fst (KeyedMap.max_binding entry.children));
                      string_dump entry.highest_key;
                      failwith "children invariant broken"
                  | Some (sk, _cl) ->
                      scored_key := sk );
                let len = String.length va in
                let len1 = P.key_size + sizeof_datalen + len in
                spill_score := !spill_score + len1 )
              entry.logdata.contents;
            if !spill_score > !best_spill_score then (
              best_spill_score := !spill_score;
              best_spill_key := !scored_key );
            (!best_spill_score, !best_spill_key)
          in
          let best_spill_score, best_spill_key = find_victim () in
          Logs.debug (fun m ->
              m "log spilling %Ld %Ld %d" depth alloc_id best_spill_score );
          let%lwt child_alloc_id, _ce =
            preload_child fs alloc_id entry best_spill_key
          in
          let clc = KeyedMap.length entry.children in
          let nko = entry.logdata.value_end in
          (*Logs.debug (fun m -> m "Before _reserve_insert nko %d" entry.logdata.value_end);*)
          reserve_insert fs child_alloc_id (InsSpaceValue best_spill_score)
            false (Int64.succ depth)
          >>= fun () ->
          (*Logs.debug (fun m -> m "After _reserve_insert nko %d" entry.logdata.value_end);*)
          if
            clc = KeyedMap.length entry.children
            && nko = entry.logdata.value_end
          then (
            (* _reserve_insert didn't split the child or the root *)
            reserve_dirty fs.node_cache child_alloc_id 0L (Int64.succ depth);
            let before_bsk_succ =
              match KeyedMap.find_last_opt entry.children best_spill_key with
              | Some (before_bsk, _va) ->
                  next_key before_bsk
              | None ->
                  zero_key
            in
            (* which keys we will dispatch *)
            let carved_list =
              KeyedMap.carve_inclusive_range entry.logdata.contents
                before_bsk_succ best_spill_key
            in
            entry.logdata.value_end
            <- entry.logdata.value_end - best_spill_score;
            KeyedMap.iter
              (fun key va ->
                fast_insert fs child_alloc_id key (InsValue va)
                  (Int64.succ depth) )
              carved_list );
          reserve_insert fs alloc_id space split_path depth )
        else
          match entry.meta with
          | Root -> (
              (* Node splitting (root) *)
              assert (depth = 0L);
              Logs.debug (fun m -> m "node splitting %Ld %Ld" depth alloc_id);
              let kc = entry.logdata.contents in
              reserve_dirty fs.node_cache alloc_id 2L depth;
              lru_reserve fs.node_cache.lru 2;
              let di = mark_dirty fs.node_cache alloc_id in
              let median = split_point entry in
              match median with
              |None -> raise UnableToSplit
              |Some median ->
              assert (median != entry.highest_key);
              let alloc1, entry1 =
                new_node fs 2 (Some alloc_id) median entry.rdepth
              in
              let alloc2, entry2 =
                new_node fs 2 (Some alloc_id) entry.highest_key entry.rdepth
              in
              let kc2 = KeyedMap.split_off_after kc median in
              let cl2 = KeyedMap.split_off_after entry.children median in
              let ca2 =
                KeyedMap.split_off_after entry.children_alloc_ids median
              in
              let fc2 = KeyedMap.split_off_after di median in
              KeyedMap.iter
                (fun _k va ->
                  entry1.logdata.value_end
                  <- entry1.logdata.value_end
                     + String.length va
                     + P.key_size
                     + sizeof_datalen )
                kc;
              KeyedMap.iter
                (fun _k va ->
                  entry2.logdata.value_end
                  <- entry2.logdata.value_end
                     + String.length va
                     + P.key_size
                     + sizeof_datalen )
                kc2;
              KeyedMap.swap entry1.children entry.children;
              KeyedMap.swap entry2.children cl2;
              KeyedMap.swap entry1.logdata.contents kc;
              KeyedMap.swap entry2.logdata.contents kc2;
              KeyedMap.swap entry1.children_alloc_ids entry.children_alloc_ids;
              KeyedMap.swap ca2 entry2.children_alloc_ids;
              reset_contents entry;
              entry.rdepth <- Int32.succ entry.rdepth;
              entry.flush_children <- Some (KeyedMap.create ());
              fixup_parent_links fs.node_cache alloc1 entry1;
              fixup_parent_links fs.node_cache alloc2 entry2;
              add_child entry entry1 alloc1 fs.node_cache alloc_id;
              add_child entry entry2 alloc2 fs.node_cache alloc_id;
              entry1.flush_children <- Some di;
              entry2.flush_children <- Some fc2;
              Lwt.return_unit)
          | Child parent_key -> (
              (* Node splitting (non root) *)
              assert (Int64.compare depth 0L > 0);
              Logs.debug (fun m -> m "node splitting %Ld %Ld" depth alloc_id);
              (* Set split_path to prevent spill/split recursion; will split towards the root *)
              reserve_insert fs parent_key (InsSpaceChild childlink_size) true
                (Int64.pred depth)
              >>= fun () ->
              (* The parent _reserve_insert call may have split the root, causing the parent_key
               to be updated *)
              let parent_key =
                match entry.meta with
                | Child parent_key ->
                    parent_key
                | _ ->
                    assert false
              in
              reserve_dirty fs.node_cache alloc_id 1L depth;
              lru_reserve fs.node_cache.lru 1;
              let di = mark_dirty fs.node_cache alloc_id in
              let median = split_point entry in
              match median with
              |None -> raise UnableToSplit
              |Some median ->
              if (median == entry.highest_key) then Logs.err (fun m -> m "Bad split %d %d" (KeyedMap.length entry.children) (KeyedMap.length entry.logdata.contents));
              assert (median != entry.highest_key);
              let alloc1, entry1 =
                new_node fs 2 (Some parent_key) median entry.rdepth
              in
              let remove_size = ref 0 in
              let kc1 = KeyedMap.split_off_le entry.logdata.contents median in
              KeyedMap.iter
                (fun key va ->
                  let len = String.length va in
                  let len1 = len + P.key_size + sizeof_datalen in
                  fast_insert fs alloc1 key (InsValue va) depth;
                  remove_size := !remove_size + len1 )
                kc1;
              entry.logdata.value_end
              <- entry.logdata.value_end - !remove_size;
              let children1 = KeyedMap.split_off_le entry.children median in
              let ca1 =
                KeyedMap.split_off_le entry.children_alloc_ids median
              in
              entry1.children <- children1;
              entry1.children_alloc_ids <- ca1;
              let fc1 = KeyedMap.split_off_le di median in
              entry1.flush_children <- Some fc1;
              fixup_parent_links fs.node_cache alloc1 entry1;
              (* Hook new node into parent *)
              match lru_peek fs.node_cache.lru parent_key with
              | None ->
                  Logs.err (fun m ->
                      m "Missing LRU entry for %Ld (parent)" alloc_id );
                  raise (MissingLRUEntry parent_key)
              | Some parent ->
                  ( add_child parent entry1 alloc1 fs.node_cache parent_key;
                    match parent.flush_children with
                    | None ->
                        failwith "Missing flush_info for parent"
                    | Some di ->
                        KeyedMap.add di median alloc1 );
                  reserve_insert fs alloc_id space split_path depth ) )

  let insert root key value =
    Statistics.add_insert root.open_fs.node_cache.statistics;
    check_live_integrity root.open_fs root.root_key 0L;
    reserve_insert root.open_fs root.root_key
      (ins_req_space (InsValue value))
      false 0L
    >>= fun () ->
    check_live_integrity root.open_fs root.root_key 0L;
    fast_insert root.open_fs root.root_key key (InsValue value) 0L;
    check_live_integrity root.open_fs root.root_key 0L;
    Lwt.return ()

  let rec lookup_rec open_fs alloc_id key =
    Logs.debug (fun m -> m "lookup_rec");
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry -> (
      match KeyedMap.find_opt entry.logdata.contents key with
      | Some va ->
          if is_value open_fs.filesystem va then Lwt.return_some va
          else Lwt.return_none
      | None ->
          if not (has_children entry) then Lwt.return_none
          else
            let key1, _logical = KeyedMap.find_first entry.children key in
            let%lwt child_alloc_id, _ce =
              preload_child open_fs alloc_id entry key1
            in
            lookup_rec open_fs child_alloc_id key )

  let rec mem_rec open_fs alloc_id key =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry -> (
      match KeyedMap.find_opt entry.logdata.contents key with
      | Some va ->
          Lwt.return (is_value open_fs.filesystem va)
      | None ->
          Logs.debug (fun m -> m "_mem");
          if not (has_children entry) then Lwt.return_false
          else
            let key1, _logical = KeyedMap.find_first entry.children key in
            let%lwt child_alloc_id, _ce =
              preload_child open_fs alloc_id entry key1
            in
            mem_rec open_fs child_alloc_id key )

  let lookup root key =
    Statistics.add_lookup root.open_fs.node_cache.statistics;
    lookup_rec root.open_fs root.root_key key

  let mem root key =
    Statistics.add_lookup root.open_fs.node_cache.statistics;
    mem_rec root.open_fs root.root_key key

  let rec search_range_rec open_fs alloc_id start end_ seen callback =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry ->
        let seen1 = ref seen in
        let lwt_queue = ref [] in
        (* The range from start inclusive to end_ exclusive *)
        KeyedMap.iter_range
          (fun k va ->
            ( match value_at open_fs.filesystem va with
            | Some v ->
                callback k v
            | None ->
                () );
            seen1 := KeyedSet.add k !seen1 )
          entry.logdata.contents start end_;
        (* As above, but end at end_ inclusive *)
        KeyedMap.iter_inclusive_range
          (fun key1 _logical -> lwt_queue := key1 :: !lwt_queue)
          entry.children start end_;
        Lwt_list.iter_s
          (fun key1 ->
            let%lwt child_alloc_id, _ce =
              preload_child open_fs alloc_id entry key1
            in
            search_range_rec open_fs child_alloc_id start end_ !seen1 callback
            )
          !lwt_queue

  (* The range from start inclusive to end_ exclusive
     Results are in no particular order. *)
  let search_range root start end_ callback =
    let seen = KeyedSet.empty in
    Statistics.add_range_search root.open_fs.node_cache.statistics;
    search_range_rec root.open_fs root.root_key start end_ seen callback

  let rec iter_rec open_fs alloc_id callback =
    match lru_get open_fs.node_cache.lru alloc_id with
    | None ->
        raise (MissingLRUEntry alloc_id)
    | Some entry ->
        let lwt_queue = ref [] in
        KeyedMap.iter
          (fun k va ->
            match value_at open_fs.filesystem va with
            | Some v ->
                callback k v
            | None ->
                () )
          entry.logdata.contents;
        KeyedMap.iter
          (fun key1 _logical -> lwt_queue := key1 :: !lwt_queue)
          entry.children;
        Lwt_list.iter_s
          (fun key1 ->
            let%lwt child_alloc_id, _ce =
              preload_child open_fs alloc_id entry key1
            in
            iter_rec open_fs child_alloc_id callback )
          !lwt_queue

  let iter root callback =
    Statistics.add_iter root.open_fs.node_cache.statistics;
    iter_rec root.open_fs root.root_key callback

  let read_superblock fs =
    let block_io = get_superblock_io () in
    let block_io_fanned = make_fanned_io_list fs.sector_size block_io in
    B.read fs.disk 0L block_io_fanned
    >>= Lwt.wrap1 (function
          | Result.Error _ ->
              raise ReadError
          | Result.Ok () ->
              let sb = sb_io block_io in
              if copy_superblock_magic sb <> superblock_magic then
                raise BadMagic
              else if get_superblock_version sb <> superblock_version then
                raise BadVersion
              else if get_superblock_incompat_flags sb <> sb_required_incompat
              then raise BadFlags
              else if not (cstruct_valid sb fs.mount_options.relax) then raise (BadCRC 0L)
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
                  Cstruct.to_string (get_superblock_fsid sb) ) )

  (* Requires the caller to discard the entire device first.
     Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let format open_fs logical_size first_block_written fsid =
    let block_io = get_superblock_io () in
    let block_io_fanned =
      make_fanned_io_list open_fs.filesystem.sector_size block_io
    in
    let alloc_id, _root = new_root open_fs in
    open_fs.node_cache.new_count <- 1L;
    write_node open_fs alloc_id
    >>= fun () ->
    log_cache_statistics open_fs.node_cache;
    let sb = sb_io block_io in
    set_superblock_magic superblock_magic 0 sb;
    set_superblock_version sb superblock_version;
    set_superblock_incompat_flags sb sb_required_incompat;
    set_superblock_block_size sb (Int32.of_int P.block_size);
    set_superblock_key_size sb P.key_size;
    set_superblock_first_block_written sb first_block_written;
    set_superblock_logical_size sb logical_size;
    set_superblock_fsid fsid 0 sb;
    Crc32c.cstruct_reset sb;
    B.write open_fs.filesystem.disk 0L block_io_fanned
    >>= function
    | Result.Ok () ->
        Lwt.return ()
    | Result.Error _ ->
        Lwt.fail WriteError

  let mid_range start end_ lsize =
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

  let scan_for_root fs start0 lsize fsid =
    Logs.debug (fun m -> m "scan_for_root");
    let cstr = get_block_io () in
    let io_data = make_fanned_io_list fs.sector_size cstr in
    let read logical =
      B.read fs.disk
        Int64.(
          div
            (mul logical (of_int P.block_size))
            (of_int fs.other_sector_size))
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
      && Cstruct.to_string (get_anynode_hdr_fsid cstr) = fsid
      && cstruct_valid cstr fs.mount_options.relax
    in
    let rec scan_range start end_opt =
      if Some start = end_opt then
        Lwt.fail (Failure "Didn't find a valid root")
      else
        let end_opt = if end_opt = None then Some start else end_opt in
        read start
        >>= fun () ->
        if is_valid_root () then
          Lwt.return (start, get_anynode_hdr_generation cstr)
        else scan_range (next_logical start) end_opt
    in
    let rec sfr_rec start0 end0 gen0 =
      (* end/start swapped on purpose *)
      match mid_range end0 start0 lsize with
      | None ->
          Lwt.return end0
      | Some start1 ->
          let%lwt end1, gen1 = scan_range start1 None in
          if gen0 < gen1 then sfr_rec start0 end1 gen1
          else sfr_rec start1 end0 gen0
    in
    let%lwt end0, gen0 = scan_range start0 None in
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
        let%lwt fbw, logical_size, fsid = read_superblock fs in
        let%lwt lroot = scan_for_root fs fbw logical_size fsid in
        let%lwt cstr = load_data_at fs lroot in
        let typ = get_anynode_hdr_nodetype cstr in
        if typ <> 1 then raise (BadNodeType typ);
        let root_generation = get_rootnode_hdr_generation cstr in
        let rdepth = get_rootnode_hdr_depth cstr in
        let space_map = Bitv64.create logical_size false in
        Bitv64.set space_map 0L true;
        let scan_map =
          if mount_options.fast_scan then
            Some (Bitv64.create logical_size false)
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
            statistics = Statistics.create () }
        in
        let open_fs = {filesystem = fs; node_cache} in
        (* TODO add more integrity checking *)
        scan_all_nodes open_fs lroot true rdepth Int64.max_int false
        >>= fun () ->
        let%lwt root_key, _entry = load_root_node_at open_fs lroot in
        let root = {open_fs; root_key} in
        log_statistics root;
        Lwt.return (root, root_generation)
    | FormatEmptyDevice logical_size ->
        assert (logical_size >= 2L);
        let space_map = Bitv64.create logical_size false in
        Bitv64.set space_map 0L true;
        let freed_intervals = BlockIntervals.empty in
        let free_count = Int64.pred logical_size in
        let first_block_written = Nocrypto.Rng.Int64.gen_r 1L logical_size in
        let fsid = Cstruct.to_string (Nocrypto.Rng.generate 16) in
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
            statistics = Statistics.create () }
        in
        let open_fs = {filesystem = fs; node_cache} in
        format open_fs logical_size first_block_written fsid
        >>= fun () ->
        let root_key = 1L in
        Lwt.return ({open_fs; root_key}, 1L)
end

type open_ret =
  | OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

let open_for_reading (type disk) (module B : EXTBLOCK with type t = disk) disk
    mount_options =
  read_superblock_params (module B) disk mount_options.relax
  >>= function
  | sp -> (
      let module Stor = Make (B) ((val sp)) in
      Stor.prepare_io OpenExistingDevice disk mount_options
      >>= function
      | root, gen ->
          Lwt.return (OPEN_RET ((module Stor), root, gen)) )
