open Lwt.Infix

let superblock_magic = "kvqnsfmnlsvqfpge"
let superblock_version = 1l


exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC

exception ReadError
exception WriteError

exception BadKey of Cstruct.t
exception ValueTooLarge of Cstruct.t
exception BadNodeType of int

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
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * separation: at least at uint64_t of all zeroes
 * disambiguates from a valid logical offset
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
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
 * optional padding
 * crc *)

let sizeof_datalen = 2

let sizeof_logical = 8

let rec make_fanned_io_list size cstr =
  if Cstruct.len cstr = 0 then []
  else let head, rest = Cstruct.split cstr size in
  head::make_fanned_io_list size rest

type childlinks = {
  (* starts at blocksize - sizeof_crc, if there are no children *)
  mutable childlinks_offset: int;
}

type keydata_index = {
  (* in descending order. if the list isn't empty,
   * last item must be sizeof_*node_hdr *)
  mutable keydata_offsets: int list;
  mutable next_keydata_offset: int;
}

(* Use offsets so that data isn't duplicated
 * Don't reference nodes directly, always go through the
 * LRU to bump recently accessed nodes *)
type childlink_entry = [
  |`CleanChild of int (* offset, logical is at offset + P.key_size *)
  |`DirtyChild of int (* offset, logical is at offset + P.key_size *)
  |`AnonymousChild of int ] (* offset, alloc_id is at offset + P.key_size *)

let offset_of_cl = function
  |`CleanChild off
  |`DirtyChild off
  |`AnonymousChild off ->
      off

type node = [
  |`Root of Cstruct.t * keydata_index * childlinks
  |`Inner of Cstruct.t * keydata_index * childlinks
  |`Leaf of Cstruct.t * keydata_index]

let cstruct_of_node = function
  |`Root (cstr, _, _)
  |`Inner (cstr, _, _)
  |`Leaf (cstr, _) -> cstr

let keydata_of_node = function
  |`Root (_, kd, _)
  |`Inner (_, kd, _)
  |`Leaf (_, kd) -> kd

let generation_of_node node =
  get_anynode_hdr_generation @@ cstruct_of_node node

let has_childen = function
  |`Root _
  |`Inner _ -> true
  |_ -> false

type dirty_node = {
  dirty_node: node;
  mutable dirty_children: dirty_node list;
}

module CstructKeyedMap = Map_pr869.Make(Cstruct)

type cache_state = NoKeysCached | LogKeysCached | AllKeysCached

type lru_entry = {
  cached_node: node;
  (* None if not dirty *)
  mutable cached_dirty_node: dirty_node option;
  (* 0 if not anonymous *)
  alloc_id: int64;
  mutable children: childlink_entry CstructKeyedMap.t;
  mutable logindex: int CstructKeyedMap.t;
  mutable highest_key: Cstruct.t;
  mutable cache_state: cache_state;
}

module LRUKey = struct
  type t = ByLogical of int64 | ByAllocId of int64 | Sentinel
  let compare = compare
  let witness = Sentinel
  let hash = Hashtbl.hash
  let equal = (=)
end

module LRU = Lru_cache.Make(LRUKey)
module ParentCache = Ephemeron.K1.Make(LRUKey)

type node_cache = {
  (* LRUKey.t -> LRUKey.t *)
  parent_links: LRUKey.t ParentCache.t;
  (* LRUKey.t -> lru_entry
   * keeps the ParentCache alive
   * anonymous nodes are keyed by their alloc_id,
   * everybody else by their generation *)
  lru: lru_entry LRU.t;
  (* tree_id -> dirty_node *)
  dirty_roots: (int32, dirty_node) Hashtbl.t;
  next_alloc_id: int64;
  (* The next generation number we'll allocate *)
  (*mutable next_generation: int64;*)
}

let rec mark_dirty cache lru_key =
  let entry = LRU.get cache.lru lru_key
  (fun _ -> failwith "Missing LRU key") in
  let new_dn () =
    { dirty_node = entry.cached_node; dirty_children = []; } in
  match entry.cached_dirty_node with Some dn -> dn | None -> let dn = begin
    match entry.cached_node with
    |`Root (cstr, _, _) ->
        let tree_id = get_rootnode_hdr_tree_id cstr in
        begin match Hashtbl.find_all cache.dirty_roots tree_id with
          |[] -> begin let dn = new_dn () in Hashtbl.add cache.dirty_roots tree_id dn; dn end
          |[dn] -> dn
          |_ -> failwith "dirty_roots inconsistent" end
    |`Inner _
    |`Leaf _ ->
        match ParentCache.find_all cache.parent_links lru_key with
        |[parent_key] ->
            let parent_entry = LRU.get cache.lru parent_key
            (fun _ -> failwith "missing parent_entry") in
            let parent_dn = mark_dirty cache parent_key in
        begin
          match List.filter (fun dn -> dn.dirty_node == entry.cached_node) parent_dn.dirty_children with
            |[] -> begin let dn = new_dn () in parent_dn.dirty_children <- dn::parent_dn.dirty_children; dn end
            |[dn] -> dn
            |_ -> failwith "dirty_node inconsistent" end
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
    if Cstruct.len key <> P.key_size
    then raise @@ BadKey key
    else key

  let check_value_len value =
    let len = Cstruct.len value in
    if len >= 65536 then raise @@ ValueTooLarge value else len

  let block_end = P.block_size - sizeof_crc

  let _load_node cache cstr logical highest_key parent_key =
    let () = assert (Cstruct.len cstr = P.block_size) in
    if not (Crc32c.cstruct_valid cstr)
    then raise BadCRC
    else let node =
      match get_anynode_hdr_nodetype cstr with
      |1 -> `Root (cstr,
        {keydata_offsets=[]; next_keydata_offset=sizeof_rootnode_hdr;},
        {childlinks_offset=block_end;})
      |2 -> `Inner (cstr,
        {keydata_offsets=[]; next_keydata_offset=sizeof_innernode_hdr;},
        {childlinks_offset=block_end;})
      |3 -> `Leaf (cstr,
        {keydata_offsets=[]; next_keydata_offset=sizeof_leafnode_hdr;})
      |ty -> raise @@ BadNodeType ty
    in
      let key = LRUKey.ByLogical logical in
      let entry = {cached_node=node; cached_dirty_node=None; alloc_id=0L; children=CstructKeyedMap.empty; logindex=CstructKeyedMap.empty; cache_state=NoKeysCached; highest_key;} in
      let entry1 = LRU.get cache.lru key (fun _ -> entry) in
      let () = assert (entry == entry1) in
      begin match parent_key with
        |Some pk -> ParentCache.add cache.parent_links pk key
        |_ -> ()
      end;
      entry

  let _load_node_at open_fs logical highest_key parent_key =
    (* TODO perform IO *)
    failwith "_load_node_at"

  let flush cache = ()

  let free_space = function
    |`Root (_, kd, cl)
    |`Inner (_, kd, cl) -> cl.childlinks_offset - kd.next_keydata_offset - sizeof_logical
    |`Leaf (_, kd) -> P.block_size - kd.next_keydata_offset - sizeof_crc

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

  type open_fs = {
    filesystem: filesystem;
    node_cache: node_cache;
  }

  type root = {
    open_fs: open_fs;
    root_key: LRUKey.t;
  }

  let entry_of_root root =
    LRU.get root.open_fs.node_cache.lru root.root_key
    (fun _ -> failwith "missing root")

  let insert root key value =
    let key = check_key key in
    let len = check_value_len value in
    let entry = entry_of_root root in
    let free = free_space entry.cached_node in
    let len1 = P.key_size + sizeof_datalen + len in
    let blit_keydata cstr kd =
      let off = kd.next_keydata_offset in begin
        kd.next_keydata_offset <- kd.next_keydata_offset + len1;
        Cstruct.blit key 0 cstr off P.key_size;
        Cstruct.LE.set_uint16 cstr (off + P.key_size) len;
        Cstruct.blit value 0 cstr kd.next_keydata_offset len;
    end in begin
      match entry.cached_node with
      |`Leaf (cstr, kd) ->
          if free < len1
          then failwith "Implement leaf splitting"
          else blit_keydata cstr kd
      |`Inner (cstr, kd, _)
      |`Root (cstr, kd, _) ->
          if free < len1
          then failwith "Implement log spilling"
          else blit_keydata cstr kd
    end;
    ()

  let _cache_keydata cache cached_node =
    let kd = keydata_of_node cached_node.cached_node in
    cached_node.logindex <- List.fold_left (
      fun acc off ->
        let key = Cstruct.sub (
          cstruct_of_node cached_node.cached_node) off P.key_size in
        CstructKeyedMap.add key off acc)
      CstructKeyedMap.empty kd.keydata_offsets

  let rec _gen_childlink_offsets start =
    if start >= P.block_size - sizeof_crc then []
    else start::(_gen_childlink_offsets @@ start + P.key_size + sizeof_logical)

  let _cache_children cache cached_node =
    match cached_node.cached_node with
    |`Leaf _ -> failwith "leaves have no children"
    |`Root (_, _, cl)
    |`Inner (_, _, cl) ->
        cached_node.children <- List.fold_left (
          fun acc off ->
            let key = Cstruct.sub (
              cstruct_of_node cached_node.cached_node) off P.key_size in
            CstructKeyedMap.add key (`CleanChild off) acc)
          CstructKeyedMap.empty (_gen_childlink_offsets cl.childlinks_offset)

  let _read_data_from_log cached_node key = ()

  let _data_of_cl cstr cl =
    let off = offset_of_cl cl in
    Cstruct.LE.get_uint64 cstr (off + P.key_size)

  let _lru_key_of_cl cstr cl =
    let data = _data_of_cl cstr cl in match cl with
    |`CleanChild _
    |`DirtyChild _ ->
        LRUKey.ByLogical data
    |`AnonymousChild _ ->
        LRUKey.ByAllocId data

  let rec _lookup open_fs lru_key key =
    let cached_node = LRU.get open_fs.node_cache.lru lru_key
    (fun _ -> failwith "Missing LRU entry") in
    let cstr = cstruct_of_node cached_node.cached_node in
    if cached_node.cache_state = NoKeysCached then
      _cache_keydata open_fs.node_cache cached_node;
      cached_node.cache_state <- LogKeysCached;
      match
        CstructKeyedMap.find key cached_node.logindex
      with
        |logoffset ->
            let len = Cstruct.LE.get_uint16 cstr (logoffset + P.key_size) in
            Cstruct.sub cstr (logoffset + P.key_size + 2) len
        |exception Not_found ->
            if has_childen cached_node.cached_node then
            if cached_node.cache_state = LogKeysCached then
              _cache_children open_fs.node_cache cached_node;
            let key1, cl = CstructKeyedMap.find_first (
              fun k -> Cstruct.compare k key >= 0) cached_node.children in
            match cl with
            |`CleanChild _ ->
                let logical = _data_of_cl cstr cl in
                let child_lru_key = LRUKey.ByLogical logical in
                let child_entry = LRU.get open_fs.node_cache.lru child_lru_key
                (fun _ -> _load_node_at open_fs logical key1 (Some lru_key)) in
                _lookup open_fs child_lru_key key
            |`DirtyChild _
            |`AnonymousChild _ ->
                let child_lru_key = _lru_key_of_cl cstr cl in
                let child_entry = LRU.get open_fs.node_cache.lru child_lru_key
                (fun _ -> failwith "Missing LRU entry for anonymous/dirty child") in
                _lookup open_fs child_lru_key key

  let lookup root key =
    let key = check_key key in
    _lookup root.open_fs root.root_key key

  let _sb_io block_io =
    Cstruct.sub block_io 0 sizeof_superblock

  let _read_superblock fs =
    B.read fs.disk 0L fs.block_io_fanned >>= Lwt.wrap1 begin function
      |`Error _ -> raise ReadError
      |`Ok () ->
          let sb = _sb_io fs.block_io in
      if Cstruct.to_string @@ get_superblock_magic sb <> superblock_magic
      then raise BadMagic
      else if get_superblock_version sb <> superblock_version
      then raise BadVersion
      else if get_superblock_incompat_flags sb <> 0l
      then raise BadFlags
      else if not @@ Crc32c.cstruct_valid sb
      then raise BadCRC
      else () end

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

