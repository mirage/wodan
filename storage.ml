open Lwt.Infix

let superblock_magic = "kvqnsfmnlsvqfpge"
let superblock_version = 1l


exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC

exception ReadError
exception WriteError

exception BadKey of string
exception ValueTooLarge of Cstruct.t

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  key_size: uint8_t;
  first_block_written: uint64_t;
  reserved: uint8_t [@len 467];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (sizeof_superblock = 512)

let sizeof_crc = 4

[%%cstruct type anynode_hdr = {
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]

[%%cstruct type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype: uint8_t;
  (* will this wrap? there's no uint128_t *)
  generation: uint64_t;
  tree_id: uint32_t;
  prev_tree: uint64_t;
}[@@little_endian]]
(* Contents: child node links, and logged data *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: length-prefixed strings, grow from the left end towards the right
 * separation: at least one nul byte
 * child links: logical offsets, grow from the right end towards the left
 * crc *)

[%%cstruct type innernode_hdr = {
  (* nodetype = 2 *)
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]
(* Contents: child node links, and logged data *)
(* Layout: see above *)

[%%cstruct type leafnode_hdr = {
  (* nodetype = 3 *)
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]
(* Contents: keys and data *)
(* leafnode_hdr
 * (key, datalen, data)*
 * crc *)

let sizeof_datalen = 2

type nonleaf = {
  (* in descending order. if the list isn't empty, last item must be
   * sizeof_rootnode_hdr or sizeof_innernode_hdr respectively *)
  mutable logdata_offsets: int list;
  mutable next_logdata_offset: int;
  (* starts at blocksize - sizeof_crc, if there are no children *)
  mutable childlinks_offset: int;
}

type leaf = {
  (* in descending order *)
  mutable keydata_offsets: int list;
  mutable next_keydata_offset: int;
}

type node = [
  |`Root of Cstruct.t * nonleaf
  |`Inner of Cstruct.t * nonleaf
  |`Leaf of Cstruct.t * leaf]


let cstruct_of_node = function
  |`Root (cstr, _)
  |`Inner (cstr, _)
  |`Leaf (cstr, _) -> cstr

let generation_of_node node =
  get_anynode_hdr_generation @@ cstruct_of_node node

let free_space = function
  |`Root (cstr, nl)
  |`Inner (cstr, nl) -> nl.childlinks_offset - nl.next_logdata_offset - 1
  |`Leaf (cstr, lf) -> (Cstruct.len cstr) - lf.next_keydata_offset - sizeof_crc

let rec make_fanned_io_list size cstr =
  if Cstruct.len cstr = 0 then []
  else let head, rest = Cstruct.split cstr size in
  head::make_fanned_io_list size rest

type dirty_node = {
  dirty_node: node;
  mutable dirty_children: dirty_node list;
}

type lru_entry = {
  mutable cached_dirty_node: dirty_node option;
  cached_node: node;
}

module CachedNode = struct
  type t = node
  (* modulo 2**31 or 2**63 *)
  let hash a = Int64.to_int (generation_of_node a)
  let equal a b = Int64.equal (generation_of_node a) (generation_of_node b)
end

module ParentCache = Ephemeron.K1.Make(CachedNode)

module LRUKey = struct
  (* old_generation *)
  type t = int64
  let compare = Int64.compare
  let witness = Int64.zero
end

module LRU = Lru_cache.Make(LRUKey)

type node_cache = {
  (* node -> node *)
  parent_links: node ParentCache.t;
  (* old_generation -> lru_entry
   * keeps entry.cached_node alive in the ParentCache *)
  lru: lru_entry LRU.t;
  (* tree_id -> dirty_node *)
  dirty_roots: (int32, dirty_node) Hashtbl.t;
}

let rec mark_dirty cache old_generation =
  let entry = LRU.get cache.lru old_generation
  (fun og -> failwith "Missing old_generation") in
  let new_dn () =
    { dirty_node = entry.cached_node; dirty_children = []; } in
  match entry.cached_dirty_node with Some dn -> dn | None -> let dn = begin
    match entry.cached_node with
    |`Root (cstr, _) ->
        let tree_id = get_rootnode_hdr_tree_id cstr in
        begin match Hashtbl.find_all cache.dirty_roots tree_id with
          |[] -> begin let dn = new_dn () in Hashtbl.add cache.dirty_roots tree_id dn; dn end
          |[dn] -> dn
          |_ -> failwith "dirty_roots inconsistent" end
    |`Inner _
    |`Leaf _ ->
        match ParentCache.find_all cache.parent_links entry.cached_node with
        |[parent] -> let parent_dn = mark_dirty cache (generation_of_node parent) in
          match List.filter (fun dn -> dn.dirty_node == entry.cached_node) parent_dn.dirty_children with
            |[] -> begin let dn = new_dn () in parent_dn.dirty_children <- dn::parent_dn.dirty_children; dn end
            |[dn] -> dn
            |_ -> failwith "dirty_node inconsistent"
    |_ -> failwith "parent_links inconsistent"
  end in entry.cached_dirty_node <- Some dn; dn

module type PARAMS = sig
  (* in bytes *)
  val block_size: int
  (* in bytes *)
  val key_size: int
end

module StandardParams : PARAMS = struct
  let block_size = 256*1024
  let key_size = 20;
end

type deviceOpenMode = OpenExistingDevice|FormatEmptyDevice


module Make(B: V1_LWT.BLOCK)(P: PARAMS) = struct
  type key = string

  let check_key key =
    if String.length key <> P.key_size
    then Lwt.fail @@ BadKey key
    else Lwt.return key

  let rec insert node key value =
    let%lwt key = check_key key in
    let len = Cstruct.len value in
    if len >= 65536 then Lwt.fail @@ ValueTooLarge value else
    let free = free_space node in
    match node with
    |`Leaf (cstr, lf) ->
        let len1 = P.key_size + sizeof_datalen + len in
        if free < len1
        then failwith "Implement leaf splitting"
        else let off = lf.next_keydata_offset in
        let () = lf.next_keydata_offset <- lf.next_keydata_offset + len1 in
        let () = Cstruct.blit_from_string key 0 cstr off P.key_size in
        let () = Cstruct.LE.set_uint16 cstr (off + P.key_size) len in
        Lwt.return @@ Cstruct.blit value 0 cstr lf.next_keydata_offset len

  type filesystem = {
    (* Backing device *)
    disk: B.t;
    (* The exact size of IO the BLOCK accepts.
     * Even larger powers of two won't work *)
    (* 4096 with target=unix, 512 with virtualisation *)
    sector_size: int;
    (* IO on an erase block *)
    block_io: Cstruct.t;
    (* A view on block_io split as sector_size sized views *)
    block_io_fanned: Cstruct.t list;
  }

  let _sb_io block_io =
    Cstruct.sub block_io 0 sizeof_superblock

  let _read_superblock fs =
    B.read fs.disk 0L fs.block_io_fanned >>= function
      |`Error _ -> Lwt.fail ReadError
      |`Ok () ->
          let sb = _sb_io fs.block_io in
      if Cstruct.to_string @@ get_superblock_magic sb <> superblock_magic
      then Lwt.fail BadMagic
      else if get_superblock_version sb <> superblock_version
      then Lwt.fail BadVersion
      else if get_superblock_incompat_flags sb <> 0l
      then Lwt.fail BadFlags
      else if not @@ Crc32c.cstruct_valid sb
      then Lwt.fail BadCRC
      else Lwt.return ()

  (* Just the superblock for now.
   * Requires the caller to discard the entire device first.
   * Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let _format fs =
    let sb = _sb_io fs.block_io in
    let () = set_superblock_magic superblock_magic 0 sb in
    let () = set_superblock_version sb superblock_version in
    let () = set_superblock_block_size sb (Int32.of_int P.block_size) in
    let () = Crc32c.cstruct_reset sb in
    B.write fs.disk 0L fs.block_io_fanned >>= function
      |`Ok () -> Lwt.return ()
      |`Error _ -> Lwt.fail WriteError

  let prepare_io mode disk =
    B.get_info disk >>= fun info ->
      let sector_size = info.B.sector_size in
      let block_size = P.block_size in
      let page_size = Io_page.page_size in
      let () = assert (block_size >= page_size) in
      let () = assert (page_size >= sector_size) in
      let () = assert (block_size mod page_size = 0) in
      let () = assert (page_size mod sector_size = 0) in
      let block_io = Io_page.get_buf ~n:(block_size/page_size) () in
      let fs = {
        disk;
        sector_size;
        block_io;
        block_io_fanned = make_fanned_io_list sector_size block_io;
      } in match mode with
        |OpenExistingDevice -> let%lwt () = _read_superblock fs in Lwt.return fs
        |FormatEmptyDevice -> let%lwt () = _format fs in Lwt.return fs

  let write_block fs logical = failwith "write_block"

  let read_block fs logical = failwith "read_block"

  let find_newest_root fs = failwith "find_newest_root"
end

