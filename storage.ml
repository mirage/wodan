open Lwt.Infix

let superblock_magic = "kvqnsfmnlsvqfpge"
let superblock_version = 1l
let max_dirty = 128


exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC

exception ReadError
exception WriteError

exception BadKey of Cstruct.t
exception ValueTooLarge of Cstruct.t
exception BadNodeType of int

exception TryAgain

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  (* TODO make this a per-tree setting *)
  key_size: uint8_t;
  first_block_written: uint64_t;
  logical_size: uint64_t;
  reserved: uint8_t [@len 459];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (String.length superblock_magic = 16)
let () = assert (sizeof_superblock = 512)

let sizeof_crc = 4

[%%cstruct type anynode_hdr = {
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]

[%%cstruct type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype: uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation: uint64_t;
  tree_id: uint32_t;
  next_tree_id: uint32_t;
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
  (* starts at block_size - sizeof_crc, if there are no children *)
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

let offset_of_cl : childlink_entry -> int = function
  |`CleanChild off
  |`DirtyChild off
  |`AnonymousChild off ->
      off

type node = [
  |`Root of childlinks
  |`Inner of childlinks
  |`Leaf]

let has_childen = function
  |`Root _
  |`Inner _ -> true
  |_ -> false

let is_root = function
  |`Root _ -> true
  |_ -> false

module CstructKeyedMap = Map_pr869.Make(Cstruct)
module RootMap = Map.Make(Int32)

module LRUKey = struct
  type t = ByLogical of int64 | ByAllocId of int64 | Sentinel
  let compare = compare
  let witness = Sentinel
  let hash = Hashtbl.hash
  let equal = (=)
end

type dirty_info = {
  (* These LRU keys are of the form ByAllocId alloc_id *)
  mutable dirty_children: LRUKey.t list;
}

type cache_state = NoKeysCached | LogKeysCached | AllKeysCached

type lru_entry = {
  cached_node: node;
  (* A node is dirty iff it's referenced from dirty_roots
     through a dirty_children list.
     We use an option here to make checking for dirtiness faster *)
  mutable dirty_info: dirty_info option;
  mutable children: childlink_entry CstructKeyedMap.t;
  mutable logindex: int CstructKeyedMap.t;
  mutable highest_key: Cstruct.t;
  mutable cache_state: cache_state;
  raw_node: Cstruct.t;
  io_data: Cstruct.t list;
  keydata: keydata_index;
}

let generation_of_node entry =
  get_anynode_hdr_generation entry.raw_node

module LRU = Lru_cache.Make(LRUKey)
(* LRUKey.t -> parent LRUKey.t *)
(* parent is only alive as long as the lru_key is *)
(* TODO: use LRUKey.t in more places where alloc_id is used, to ensure liveness *)
module ParentCache = Ephemeron.K1.Make(LRUKey)

type node_cache = {
  (* LRUKey.t -> LRUKey.t *)
  parent_links: LRUKey.t ParentCache.t;
  (* LRUKey.t -> lru_entry
   * keeps the ParentCache alive
   * anonymous nodes are keyed by their alloc_id,
   * everybody else by their generation *)
  lru: lru_entry LRU.t;
  (* tree_id -> ByAllocId alloc_id *)
  dirty_roots: (int32, LRUKey.t) Hashtbl.t;
  mutable next_tree_id: int32;
  mutable next_alloc_id: int64;
  (* The next generation number we'll allocate *)
  mutable next_generation: int64;
  (* The next logical address we'll allocate (if free) *)
  mutable next_logical_alloc: int64;
  mutable free_count: int64;
  logical_size: int64;
  (* Logical -> bit.  Zero iff free. *)
  space_map: Bitv.t;
}

let next_logical_novalid cache logical =
  let log1 = Int64.succ logical in
  if log1 = cache.logical_size then 1L else log1

let next_logical_alloc_valid cache =
  if cache.free_count = 0L then failwith "No free space";
  let rec after log =
    if not @@ Bitv.get cache.space_map (Int64.to_int log (*XXX*)) then log else
      after @@ Int64.succ log
  in let loc = after cache.next_logical_alloc in
  cache.next_logical_alloc <- next_logical_novalid cache loc; loc

let next_tree_id cache =
  let r = cache.next_tree_id in
  let () = cache.next_tree_id <- Int32.add cache.next_tree_id 1l in
  r

let next_alloc_id cache =
  let r = cache.next_alloc_id in
  let () = cache.next_alloc_id <- Int64.add cache.next_alloc_id 1L in
  r

let next_generation cache =
  let r = cache.next_generation in
  let () = cache.next_generation <- Int64.add cache.next_generation 1L in
  r

let rec mark_dirty cache lru_key : dirty_info =
  Logs.info (fun m -> m "mark_dirty");
  let entry = LRU.get cache.lru lru_key
  (fun _ -> failwith "Missing LRU key") in
  match entry.dirty_info with
  |None -> begin
    match entry.cached_node with
    |`Root _ ->
        let tree_id = get_rootnode_hdr_tree_id entry.raw_node in
        begin match Hashtbl.find_all cache.dirty_roots tree_id with
          |[] -> begin Hashtbl.add cache.dirty_roots tree_id lru_key end
          |_ -> failwith "dirty_roots inconsistent" end
    |`Inner _
    |`Leaf ->
        match ParentCache.find_all cache.parent_links lru_key with
        |[parent_key] ->
            let _parent_entry = LRU.get cache.lru parent_key
            (fun _ -> failwith "missing parent_entry") in
            let parent_di = mark_dirty cache parent_key in
        begin
          match List.filter (fun lk -> lk == lru_key) parent_di.dirty_children with
            |[] -> begin parent_di.dirty_children <- lru_key::parent_di.dirty_children end
            |_ -> failwith "dirty_node inconsistent" end
        |_ -> failwith "parent_links inconsistent";
    end; let di = { dirty_children=[]; } in entry.dirty_info <- Some di; di
  |Some di -> di

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

type deviceOpenMode =
  |OpenExistingDevice
  |FormatEmptyDevice of int64


module Make(B: Mirage_types_lwt.BLOCK)(P: PARAMS) = struct
  type key = string

  let check_key key =
    if Cstruct.len key <> P.key_size
    then raise @@ BadKey key
    else key

  let check_value_len value =
    let len = Cstruct.len value in
    if len >= 65536 then raise @@ ValueTooLarge value else len

  let block_end = P.block_size - sizeof_crc

  let _get_block_io () =
    Io_page.get_buf ~n:(P.block_size/Io_page.page_size) ()

  type filesystem = {
    (* Backing device *)
    disk: B.t;
    (* The exact size of IO the BLOCK accepts.
     * Even larger powers of two won't work *)
    (* 4096 with target=unix, 512 with virtualisation *)
    sector_size: int;
    (* the sector size that's used for the write offset *)
    other_sector_size: int;
    (* IO on an erase block *)
    block_io: Cstruct.t;
    (* A view on block_io split as sector_size sized views *)
    block_io_fanned: Cstruct.t list;
  }

  type open_fs = {
    filesystem: filesystem;
    node_cache: node_cache;
  }

  let _load_data_at filesystem logical =
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list filesystem.sector_size cstr in
    B.read filesystem.disk Int64.(div (mul logical @@ of_int P.block_size) @@ of_int filesystem.other_sector_size) io_data >>= Lwt.wrap1 begin function
      |Result.Error _ -> raise ReadError
      |Result.Ok () ->
          if not @@ Crc32c.cstruct_valid cstr
          then raise BadCRC
          else cstr, io_data end

  let _load_node_at open_fs logical highest_key parent_key =
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    let () = assert (Cstruct.len cstr = P.block_size) in
    (*if not (Crc32c.cstruct_valid cstr)
    then raise BadCRC
    else*) (* checked by _load_data_at *)
      let cached_node, keydata =
      match get_anynode_hdr_nodetype cstr with
      |1 -> `Root {childlinks_offset=block_end;},
        {keydata_offsets=[]; next_keydata_offset=sizeof_rootnode_hdr;}
      |2 -> `Inner {childlinks_offset=block_end;},
        {keydata_offsets=[]; next_keydata_offset=sizeof_innernode_hdr;}
      |3 -> `Leaf,
        {keydata_offsets=[]; next_keydata_offset=sizeof_leafnode_hdr;}
      |ty -> raise @@ BadNodeType ty
    in
      let key = LRUKey.ByLogical logical in
      let entry = {cached_node; raw_node=cstr; io_data; keydata; dirty_info=None; children=CstructKeyedMap.empty; logindex=CstructKeyedMap.empty; cache_state=NoKeysCached; highest_key;} in
      let entry1 = LRU.get cache.lru key (fun _ -> entry) in
      let () = assert (entry == entry1) in
      begin match parent_key with
        |Some pk -> ParentCache.add cache.parent_links pk key
        |_ -> ()
      end;
      Lwt.return entry

  let free_space entry =
    match entry.cached_node with
    |`Root cl
    |`Inner cl -> cl.childlinks_offset - entry.keydata.next_keydata_offset - sizeof_logical
    |`Leaf -> block_end - entry.keydata.next_keydata_offset

  type root = {
    open_fs: open_fs;
    root_key: LRUKey.t;
  }

  let entry_of_root root =
    LRU.get root.open_fs.node_cache.lru root.root_key
    (fun _ -> failwith "missing root")

  let zero_key = Cstruct.create P.key_size
  let top_key = Cstruct.of_string (String.make P.key_size '\255')
  let zero_data = Cstruct.create P.block_size
  let is_zero_data cstr =
    Cstruct.equal cstr zero_data

  let _write_node open_fs alloc_id =
    let key = LRUKey.ByAllocId alloc_id in
    let cache = open_fs.node_cache in
    let entry = LRU.get cache.lru key (
      fun _ -> failwith "missing lru entry in _write_node") in
    Crc32c.cstruct_reset entry.raw_node;
    let logical = next_logical_alloc_valid cache in
    Logs.info (fun m -> m "_write_node logical:%Ld" logical);
    Bitv.set cache.space_map (Int64.to_int logical) true; (* XXX are ints enough *)
    cache.free_count <- Int64.pred cache.free_count;
    B.write open_fs.filesystem.disk
        Int64.(div (mul logical @@ of_int P.block_size) @@ of_int open_fs.filesystem.other_sector_size) entry.io_data >>= function
      |Result.Ok () -> Lwt.return ()
      |Result.Error _ -> Lwt.fail WriteError

  let flush open_fs =
    Logs.info (fun m -> m "flushing %d dirty roots" (Hashtbl.length open_fs.node_cache.dirty_roots));
    let rec flush_rec (completion_list : unit Lwt.t list) lru_key = begin (* TODO write to disk *)
      let entry = LRU.get open_fs.node_cache.lru lru_key
        (fun _ -> failwith "missing lru_key") in
      let Some di = entry.dirty_info in
      let completion_list = List.fold_left flush_rec completion_list di.dirty_children in
      let LRUKey.ByAllocId alloc_id = lru_key in
      (_write_node open_fs alloc_id) :: completion_list
    end in
    Lwt.join (Hashtbl.fold (fun tid lru_key completion_list ->
        flush_rec completion_list lru_key)
      open_fs.node_cache.dirty_roots [])

  let _new_root open_fs =
    let cache = open_fs.node_cache in
    let cstr = _get_block_io () in
    let () = assert (Cstruct.len cstr = P.block_size) in
    (* going through _load_node_at would simplify things, but waste a
       bit of io and cpu computing and rechecking a crc *)
    let () = set_rootnode_hdr_nodetype cstr 1 in
    let () = set_rootnode_hdr_tree_id cstr @@ next_tree_id cache in
    let alloc_id = next_alloc_id cache in
    let key = LRUKey.ByAllocId alloc_id in
    let io_data = make_fanned_io_list open_fs.filesystem.sector_size cstr in
    let cached_node = `Root {childlinks_offset=block_end;} in
    let keydata = {keydata_offsets=[]; next_keydata_offset=sizeof_rootnode_hdr;} in
    let highest_key = top_key in
    let entry = {cached_node; raw_node=cstr; io_data; keydata; dirty_info=None; children=CstructKeyedMap.empty; logindex=CstructKeyedMap.empty; cache_state=NoKeysCached; highest_key;} in
      let entry1 = LRU.get cache.lru key (fun _ -> entry) in
      let () = assert (entry == entry1) in
      alloc_id, entry

  let insert root key value =
    let key = check_key key in
    let len = check_value_len value in
    let entry = entry_of_root root in
    let free = free_space entry in
    let len1 = P.key_size + sizeof_datalen + len in
    let blit_keydata () =
      let cstr = entry.raw_node in
      let kd = entry.keydata in
      let off = kd.next_keydata_offset in begin
        kd.next_keydata_offset <- kd.next_keydata_offset + len1;
        Cstruct.blit key 0 cstr off P.key_size;
        Cstruct.LE.set_uint16 cstr (off + P.key_size) len;
        Cstruct.blit value 0 cstr (off + P.key_size + sizeof_datalen) len;
        kd.keydata_offsets <- off::kd.keydata_offsets;
    end in begin
      match entry.cached_node with
      |`Leaf ->
          if free < len1
          then failwith "Implement leaf splitting"
          else blit_keydata ()
      |`Inner _
      |`Root _ ->
          if free < len1
          then failwith "Implement log spilling"
          else begin blit_keydata (); ignore @@ mark_dirty root.open_fs.node_cache root.root_key end
    end;
    ()

  let _cache_keydata cache cached_node =
    ignore cache;
    let kd = cached_node.keydata in
    cached_node.logindex <- List.fold_left (
      fun acc off ->
        let key = Cstruct.sub (
          cached_node.raw_node) off P.key_size in
        CstructKeyedMap.add key off acc)
      CstructKeyedMap.empty kd.keydata_offsets

  let rec _gen_childlink_offsets start =
    if start >= block_end then []
    else start::(_gen_childlink_offsets @@ start + P.key_size + sizeof_logical)

  let _cache_children cache cached_node =
    ignore cache;
    (*let () = Logs.info (fun m -> m "_cache_children") in*)
    match cached_node.cached_node with
    |`Leaf -> failwith "leaves have no children"
    |`Root cl
    |`Inner cl ->
        cached_node.children <- List.fold_left (
          fun acc off ->
            let key = Cstruct.sub (
              cached_node.raw_node) off P.key_size in
            CstructKeyedMap.add key (`CleanChild off) acc)
          CstructKeyedMap.empty (_gen_childlink_offsets cl.childlinks_offset)

  let _read_data_from_log cached_node key =
    ignore cached_node;
    ignore key;
    failwith "_read_data_from_log"

  let _data_of_cl cstr cl =
    let off = offset_of_cl cl in
    Cstruct.LE.get_uint64 cstr (off + P.key_size)

  (* LRU key for a child link *)
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
    let cstr = cached_node.raw_node in
    if cached_node.cache_state = NoKeysCached then
      _cache_keydata open_fs.node_cache cached_node;
      cached_node.cache_state <- LogKeysCached;
      match
        CstructKeyedMap.find key cached_node.logindex
      with
        |logoffset ->
            let len = Cstruct.LE.get_uint16 cstr (logoffset + P.key_size) in
            Lwt.return @@ Cstruct.sub cstr (logoffset + P.key_size + 2) len
        |exception Not_found ->
            let () = Logs.info (fun m -> m "_lookup") in
            if has_childen cached_node.cached_node then
            if cached_node.cache_state = LogKeysCached then
              _cache_children open_fs.node_cache cached_node;
            (*let () = Logs.info (fun m -> m "find_first A") in*)
            let key1, cl = CstructKeyedMap.find_first (
              fun k -> Cstruct.compare k key >= 0) cached_node.children in
            (*let () = Logs.info (fun m -> m "find_first B") in*)
            match cl with
            |`CleanChild _ ->
                let logical = _data_of_cl cstr cl in
                let child_lru_key = LRUKey.ByLogical logical in
                let%lwt _child_entry = match
                  LRU.get open_fs.node_cache.lru child_lru_key
                    (fun _ -> raise TryAgain) with
                  |ce -> Lwt.return ce
                  |exception TryAgain ->
                      _load_node_at open_fs logical key1 (Some lru_key) >>= function ce ->
                      Lwt.return @@ LRU.get open_fs.node_cache.lru child_lru_key (fun _ -> ce)
                in
                _lookup open_fs child_lru_key key
            |`DirtyChild _
            |`AnonymousChild _ ->
                let child_lru_key = _lru_key_of_cl cstr cl in
                let _child_entry = LRU.get open_fs.node_cache.lru child_lru_key
                (fun _ -> failwith "Missing LRU entry for anonymous/dirty child") in
                _lookup open_fs child_lru_key key

  let lookup root key =
    let key = check_key key in
    _lookup root.open_fs root.root_key key

  let rec _scan_all_nodes open_fs logical =
    Logs.info (fun m -> m "_scan_all_nodes %Ld" logical);
    (* TODO add more fsck style checks *)
    let cache = open_fs.node_cache in
    let log_int = Int64.to_int logical in (* XXX check truncation *)
    let sm = Bitv.get cache.space_map log_int in
    if sm then failwith "logical address referenced twice";
    Bitv.set cache.space_map log_int true;
    cache.free_count <- Int64.pred cache.free_count;
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    match get_anynode_hdr_nodetype cstr with
    |1 (* root *)
    |2 (* inner *) ->
        let rec scan_key off =
        let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
        if log1 <> 0L then let%lwt () = _scan_all_nodes open_fs log1 in scan_key (off - P.key_size - sizeof_logical) else Lwt.return ()
        in scan_key (block_end - P.key_size - sizeof_logical)
    |3 (* leaf *) -> Lwt.return ()
    |ty -> Lwt.fail (BadNodeType ty)

  let _sb_io block_io =
    Cstruct.sub block_io 0 sizeof_superblock

  let _read_superblock fs =
    B.read fs.disk 0L fs.block_io_fanned >>= Lwt.wrap1 begin function
      |Result.Error _ -> raise ReadError
      |Result.Ok () ->
          let sb = _sb_io fs.block_io in
      if Cstruct.to_string @@ get_superblock_magic sb <> superblock_magic
      then raise BadMagic
      else if get_superblock_version sb <> superblock_version
      then raise BadVersion
      else if get_superblock_incompat_flags sb <> 0l
      then raise BadFlags
      else if not @@ Crc32c.cstruct_valid sb
      then raise BadCRC
      else get_superblock_first_block_written sb, get_superblock_logical_size sb
    end

  (* Requires the caller to discard the entire device first.
     Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let _format open_fs logical_size first_block_written =
    let alloc_id, _root = _new_root open_fs in
    let%lwt () = _write_node open_fs alloc_id in
    let sb = _sb_io open_fs.filesystem.block_io in
    let () = set_superblock_magic superblock_magic 0 sb in
    let () = set_superblock_version sb superblock_version in
    let () = set_superblock_block_size sb (Int32.of_int P.block_size) in
    let () = set_superblock_first_block_written sb first_block_written in
    let () = set_superblock_logical_size sb logical_size in
    let () = Crc32c.cstruct_reset sb in
    B.write open_fs.filesystem.disk 0L open_fs.filesystem.block_io_fanned >>= function
      |Result.Ok () -> Lwt.return ()
      |Result.Error _ -> Lwt.fail WriteError

  let _mid_range start end_ lsize = (* might overflow, limit lsize *)
    (* if start = end_, we pick the farthest logical address *)
    if Int64.(succ start) = end_ || (
      Int64.(succ start) = lsize && end_ = 1L) then None else
    let end_ = if Int64.compare start end_ < 0 then end_ else Int64.(add end_ lsize) in
    let mid = Int64.(shift_right_logical (add start end_) 1) in
    let mid = Int64.(rem mid lsize) in
    let mid = if mid = 0L then 1L else mid in
    Some mid

  let _scan_for_root fs start0 lsize =
    Logs.info (fun m -> m "_scan_for_root");
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list fs.sector_size cstr in

    let read logical =
      B.read fs.disk Int64.(div (mul logical @@ of_int P.block_size) @@ of_int fs.other_sector_size) io_data >>= function
      |Result.Error _ -> Lwt.fail ReadError
      |Result.Ok () -> Lwt.return () in

    let scan_range start =
      (* Placeholder.
         TODO scan_range start end
         TODO use is_zero_data, type checks, crc checks, and loop *)
      let%lwt () = read start in
      Lwt.return (start, get_anynode_hdr_generation cstr) in

    let rec sfr_rec start0 end0 gen0 =
      (* end/start swapped on purpose *)
      match _mid_range end0 start0 lsize with
      | None -> Lwt.return end0
      | Some start1 ->
      let%lwt end1, gen1 = scan_range start1 in
      if gen0 < gen1
      then sfr_rec start0 end1 gen1
      else sfr_rec start1 end0 gen0 in

    let%lwt end0, gen0 = scan_range start0
    in sfr_rec start0 end0 gen0

  let prepare_io mode disk cache_size =
    B.get_info disk >>= fun info ->
      let sector_size = if false then info.sector_size else 4096 in
      let block_size = P.block_size in
      let page_size = Io_page.page_size in
      let () = assert (block_size >= page_size) in
      let () = assert (page_size >= sector_size) in
      let () = assert (block_size mod page_size = 0) in
      let () = assert (page_size mod sector_size = 0) in
      let block_io = _get_block_io () in
      let fs = {
        disk;
        sector_size;
        other_sector_size = info.sector_size;
        block_io;
        block_io_fanned = make_fanned_io_list sector_size block_io;
      } in
      match mode with
        |OpenExistingDevice ->
            let%lwt fbw, logical_size = _read_superblock fs in
            let%lwt lroot = _scan_for_root fs fbw logical_size in
            let%lwt cstr, _io_data = _load_data_at fs lroot in
            let typ = get_anynode_hdr_nodetype cstr in
            let () = if typ <> 1 then raise @@ BadNodeType typ in
            let root_generation = get_rootnode_hdr_generation cstr in
            let root_tree_id = get_rootnode_hdr_tree_id cstr in
            let space_map = Bitv.create (Int64.to_int logical_size) false in (* XXX unchecked truncation *)
            Bitv.set space_map 0 true;
            let free_count = Int64.pred logical_size in
            let node_cache = {
              parent_links=ParentCache.create 100;
              lru=LRU.init ~size:cache_size;
              dirty_roots=Hashtbl.create 1;
              next_tree_id=get_rootnode_hdr_next_tree_id cstr;
              next_alloc_id=1L;
              next_generation=Int64.add 1L root_generation;
              logical_size;
              space_map;
              free_count;
              next_logical_alloc=lroot; (* in use, but that's okay *)
            } in
            let open_fs = { filesystem=fs; node_cache; } in
            let%lwt () = _scan_all_nodes open_fs lroot in
            let root_key = LRUKey.ByLogical lroot in
            (* TODO parse other roots *)
            Lwt.return @@ RootMap.singleton root_tree_id {open_fs; root_key;}
        |FormatEmptyDevice logical_size ->
            let root_tree_id = 1l in
            let space_map = Bitv.create (Int64.to_int logical_size) false in (* XXX unchecked truncation *)
            Bitv.set space_map 0 true;
            let free_count = Int64.pred logical_size in
            let first_block_written = Nocrypto.Rng.Int64.gen_r 1L logical_size in
            let node_cache = {
              parent_links=ParentCache.create 100; (* use the flush size? *)
              lru=LRU.init ~size:cache_size;
              dirty_roots=Hashtbl.create 1;
              next_tree_id=root_tree_id;
              next_alloc_id=1L;
              next_generation=1L;
              logical_size;
              space_map;
              free_count;
              next_logical_alloc=first_block_written;
            } in
            let open_fs = { filesystem=fs; node_cache; } in
            let%lwt () = _format open_fs logical_size first_block_written in
            let root_key = LRUKey.ByAllocId 1L in
            Lwt.return @@ RootMap.singleton root_tree_id {open_fs; root_key;}

  let write_block fs logical =
    ignore fs;
    ignore logical;
    failwith "write_block"

  let read_block fs logical =
    ignore fs;
    ignore logical;
    failwith "read_block"

  let find_newest_root fs =
    ignore fs;
    failwith "find_newest_root"
end

