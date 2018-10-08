(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
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

open Lwt.Infix

let src = Logs.Src.create "irmin.wodan"
module Log = (val Logs.src_log src : Logs.LOG)

let standard_mount_options = {Wodan.standard_mount_options with has_tombstone = true}

module Conf = struct
  let path =
    Irmin.Private.Conf.key ~doc:"Path to filesystem image" "path"
      Irmin.Private.Conf.string "wodan.img"

  let create =
    Irmin.Private.Conf.key ~doc:"Whether to create a fresh filesystem" "create"
      Irmin.Private.Conf.bool false

  let cache_size =
    Irmin.Private.Conf.key ~doc:"How many cache items to keep in the LRU"
      "cache_size"
      Irmin.Private.Conf.int 1024

  let fast_scan =
    Irmin.Private.Conf.key ~doc:"Whether to mount without scanning the leaves"
      "fast_scan"
      Irmin.Private.Conf.bool true

  let list_key =
    Irmin.Private.Conf.key
      ~doc:"A special key used to store metadata for listing other keys"
      "list_key"
      Irmin.Private.Conf.string "meta:keys-list:00000"

  let autoflush = Irmin.Private.Conf.key
      ~doc:"Whether to flush automatically when necessary for writes to go through"
      "autoflush"
      Irmin.Private.Conf.bool false
end

let config ?(config=Irmin.Private.Conf.empty) ~path ~create ?cache_size ?fast_scan ?list_key ?autoflush () =
  let module C = Irmin.Private.Conf in
  let cache_size = match cache_size with
  |None -> C.default Conf.cache_size
  |Some cache_size -> cache_size
  in
  let fast_scan = match fast_scan with
  |None -> C.default Conf.fast_scan
  |Some fast_scan -> fast_scan
  in
  let list_key = match list_key with
  |None -> C.default Conf.list_key
  |Some list_key -> list_key
  in
  let autoflush = match autoflush with
  |None -> C.default Conf.autoflush
  |Some autoflush -> autoflush
  in
  (C.add (C.add (C.add (C.add (C.add (C.add config
    Conf.autoflush autoflush)
    Conf.list_key list_key)
    Conf.fast_scan fast_scan)
    Conf.cache_size cache_size)
    Conf.path path)
    Conf.create create)

module type BLOCK_CON = sig
  include Wodan.EXTBLOCK
  (* XXX mirage-block-unix and mirage-block-ramdisk don't have the
   * exact same signature *)
  (*val connect : name:string -> t io*)
  val connect : string -> t Lwt.t
end

module type DB = sig
  module Stor : Wodan.S
  type t
  val db_root : t -> Stor.root
  val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t
  val make : path:string -> create:bool -> mount_options:Wodan.mount_options -> autoflush:bool -> t Lwt.t
  val v : Irmin.config -> t Lwt.t
  val flush : t -> int64 Lwt.t
end

module Cache (X: sig
    type config
    type t
    type key
    val v: config -> t Lwt.t
    val key: config -> key
  end): sig
  val read : X.config -> (X.config * X.t) Lwt.t
  val clear: unit -> unit
end = struct

  (* inspired from ocaml-git/src/git/fs.ml *)

  type key = { config: X.config; w: X.t Weak.t }

  module WeakTbl = Weak.Make(struct
      type t = key
      let hash t = Hashtbl.hash @@ X.key t.config
      let equal t1 t2 = X.key t1.config = X.key t2.config
    end)

  let cache = WeakTbl.create 10
  let clear () = WeakTbl.clear cache
  let dummy = Weak.create 0 (* only used to create a search key *)

  let find config =
    try
      let search_key = { config; w = dummy } in
      let cached_value = WeakTbl.find cache search_key in
      match Weak.get cached_value.w 0 with
      | None   -> WeakTbl.remove cache cached_value; None
      | Some f -> Some (cached_value.config, f)
    with Not_found ->
      None

  let add config t =
    let w = Weak.create 1 in
    Weak.set w 0 (Some t);
    let v = { config; w } in
    Gc.finalise (fun _ -> Weak.set v.w 0 None) t; (* keep v alive *)
    WeakTbl.add cache v

  let read config =
    match find config with
    | Some v -> Lwt.return v
    | None   -> X.v config >|= fun v -> add config v; config, v
end

module DB_BUILDER
: BLOCK_CON -> Wodan.SUPERBLOCK_PARAMS -> DB
= functor (B: BLOCK_CON) (P: Wodan.SUPERBLOCK_PARAMS) ->
struct
  module Stor = Wodan.Make(B)(P)

  type t = {
    root: Stor.root;
    autoflush: bool;
  }

  let db_root db = db.root

  let do_autoflush root op =
    try%lwt
      op ()
    with Wodan.NeedsFlush ->
      Stor.flush root >>= function _gen ->
      op ()

  let may_autoflush db op =
    if db.autoflush then do_autoflush db.root op else op ()

  let make ~path ~create ~mount_options ~autoflush =
    B.connect path >>= function disk ->
    B.get_info disk >>= function info ->
    let open_arg = if create then
      Wodan.FormatEmptyDevice Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Wodan.StandardSuperblockParams.block_size)
    else Wodan.OpenExistingDevice in
    Stor.prepare_io open_arg disk mount_options >>= fun (root, _gen) ->
    Lwt.return { root; autoflush }

  module Cache = Cache(struct
      type nonrec t = t
      type config = string * bool * Wodan.mount_options * bool
      type key = string
      let key (path, _, _, _) = path
      let v (path, create, mount_options, autoflush) = make ~path ~create ~mount_options ~autoflush
    end)

  let v config =
    let module C = Irmin.Private.Conf in
    let path = C.get config Conf.path in
    let create = C.get config Conf.create in
    let cache_size = C.get config Conf.cache_size in
    let fast_scan = C.get config Conf.fast_scan in
    let autoflush = C.get config Conf.autoflush in
    let mount_options = {standard_mount_options with fast_scan = fast_scan; cache_size = cache_size} in
    Cache.read (path, create, mount_options, autoflush) >|= fun ((_, create', mount_options', autoflush'), t) ->
    assert (create=create');
    assert (mount_options=mount_options');
    assert (autoflush=autoflush');
    t

  let flush db =
    Stor.flush @@ db_root db
end

module RO_BUILDER
: BLOCK_CON -> Wodan.SUPERBLOCK_PARAMS -> functor (K: Irmin.Hash.S) -> functor (V: Irmin.Type.S) -> sig
  include Irmin.RO
  include DB with type t := t
end with type key = K.t and type value = V.t
= functor (B: BLOCK_CON) (P: Wodan.SUPERBLOCK_PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Type.S) ->
struct
  include DB_BUILDER(B)(P)
  type key = K.t
  type value = V.t

  let () = assert (K.digest_size = P.key_size)

  let find db k =
    Log.debug (fun l -> l "find %a" (Irmin.Type.pp K.t) k);
    Stor.lookup (db_root db) @@ Stor.key_of_string @@ Irmin.Type.encode_bin K.t k >>= function
    |None -> Lwt.return_none
    |Some v -> Lwt.return_some
      @@ Rresult.R.get_ok @@ Irmin.Type.decode_bin V.t @@ Stor.string_of_value v

  let mem db k =
    Log.debug (fun l -> l "mem %a" (Irmin.Type.pp K.t) k);
    Stor.mem (db_root db) @@ Stor.key_of_string @@ Irmin.Type.encode_bin K.t k
end

module AO_BUILDER
: BLOCK_CON -> Wodan.SUPERBLOCK_PARAMS -> Irmin.AO_MAKER
= functor (B: BLOCK_CON) (P: Wodan.SUPERBLOCK_PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Type.S) ->
struct
  include RO_BUILDER(B)(P)(K)(V)

  let add db va =
    let raw_v = Irmin.Type.encode_bin V.t va in
    let k = K.digest raw_v in
    Log.debug (fun m -> m "AO.add -> %a (%d)" (Irmin.Type.pp K.t) k K.digest_size);
    let raw_k = Irmin.Type.encode_bin K.t k in
    let root = db_root db in
    may_autoflush db (fun () ->
        Stor.insert root (Stor.key_of_string raw_k)
        @@ Stor.value_of_string raw_v) >>=
      function () -> Lwt.return k
end

module LINK_BUILDER
: BLOCK_CON -> Wodan.SUPERBLOCK_PARAMS -> Irmin.LINK_MAKER
= functor (B: BLOCK_CON) (P: Wodan.SUPERBLOCK_PARAMS) (K: Irmin.Hash.S) ->
struct
  include RO_BUILDER(B)(P)(K)(K)

  let add db k va =
    let raw_v = Irmin.Type.encode_bin K.t va in
    let raw_k = Irmin.Type.encode_bin K.t k in
    let root = db_root db in
    Log.debug (fun m -> m "LINK.add -> %a" (Irmin.Type.pp K.t) k);
    may_autoflush db (fun () ->
        Stor.insert root (Stor.key_of_string raw_k)
        @@ Stor.value_of_string raw_v)
end

module RW_BUILDER
: BLOCK_CON -> Wodan.SUPERBLOCK_PARAMS -> Irmin.Hash.S -> Irmin.RW_MAKER
= functor (B: BLOCK_CON) (P: Wodan.SUPERBLOCK_PARAMS) (H: Irmin.Hash.S)
(K: Irmin.Type.S) (V: Irmin.Type.S) ->
struct
  module BUILDER = DB_BUILDER(B)(P)
  module Stor = BUILDER.Stor

  module KeyHashtbl = Hashtbl.Make(Stor.Key)
  module W = Irmin.Private.Watch.Make(K)(V)
  module L = Irmin.Private.Lock.Make(K)

  type t = {
    nested: BUILDER.t;
    keydata: Stor.key KeyHashtbl.t;
    mutable magic_key: Stor.key;
    watches: W.t;
    lock: L.t;
  }

  let db_root db = BUILDER.db_root db.nested
  let may_autoflush db = BUILDER.may_autoflush db.nested

  let () = assert (H.digest_size = P.key_size)

  type key = K.t
  type value = V.t

  let key_to_inner_key k = Stor.key_of_string @@ Irmin.Type.encode_bin H.t @@ H.digest @@ Irmin.Type.encode_bin K.t k
  let val_to_inner_val va = Stor.value_of_string @@ Irmin.Type.encode_bin V.t va
  let key_to_inner_val k = Stor.value_of_string @@ Irmin.Type.encode_bin K.t k
  let key_of_inner_val va =
    Rresult.R.get_ok @@ Irmin.Type.decode_bin K.t @@ Stor.string_of_value va
  let val_of_inner_val va =
    Rresult.R.get_ok @@ Irmin.Type.decode_bin V.t
    @@ Stor.string_of_value va
  let inner_val_to_inner_key va =
    Stor.key_of_string @@ (Irmin.Type.encode_bin H.t) @@ H.digest
    @@ Stor.string_of_value va

  let make ~path ~create ~mount_options ~list_key ~autoflush =
    BUILDER.make ~path ~create ~mount_options ~autoflush >>= function db ->
      let root = BUILDER.db_root db in
      let magic_key = Bytes.make H.digest_size '\000' in
      Bytes.blit_string list_key 0 magic_key 0 (String.length list_key);
      let db = {
        nested = db;
        keydata = KeyHashtbl.create 10;
        magic_key = Stor.key_of_string (Bytes.unsafe_to_string magic_key) ;
        watches = W.v ();
        lock = L.v ();
      } in
      begin try%lwt
        while%lwt true do
          Stor.lookup root db.magic_key >>= function
            |None -> Lwt.fail Exit
            |Some va -> begin
                let ik = inner_val_to_inner_key va in
                KeyHashtbl.add db.keydata ik db.magic_key;
                db.magic_key <- Stor.next_key db.magic_key;
                Lwt.return_unit
            end
        done
      with Exit -> Lwt.return_unit
        end >>= fun () ->
          Lwt.return db

  module Cache = Cache(struct
      type nonrec t = t
      type config = string * bool * Wodan.mount_options * string * bool
      type key = string
      let key (path, _, _, _, _) = path
      let v (path, create, mount_options, list_key, autoflush) =
        make ~path ~create ~mount_options ~list_key ~autoflush
    end)

  let v config =
    let module C = Irmin.Private.Conf in
    let path = C.get config Conf.path in
    let create = C.get config Conf.create in
    let cache_size = C.get config Conf.cache_size in
    let fast_scan = C.get config Conf.fast_scan in
    let list_key = C.get config Conf.list_key in
    let autoflush = C.get config Conf.autoflush in
    let mount_options = {standard_mount_options with fast_scan = fast_scan; cache_size = cache_size} in
    Cache.read (path, create, mount_options, list_key, autoflush) >|=
    fun ((_, create', mount_options', list_key', autoflush'), t) ->
    assert (create=create');
    assert (mount_options=mount_options');
    assert (list_key=list_key');
    assert (autoflush=autoflush');
    t


  let set_and_list db ik iv ikv =
    assert (not @@ Stor.is_tombstone (db_root db) iv);
    begin if not @@ KeyHashtbl.mem db.keydata ik then begin
      KeyHashtbl.add db.keydata ik db.magic_key;
      may_autoflush db
      (fun () -> Stor.insert (db_root db) db.magic_key ikv)
      >>= fun () -> begin
        db.magic_key <- Stor.next_key db.magic_key;
        Lwt.return_unit
      end
    end
    else Lwt.return_unit end
    >>= fun () ->
    may_autoflush db
      (fun () -> Stor.insert (db_root db) ik iv)

  let set db k va =
    Log.debug (fun m -> m "RW.set -> %a" (Irmin.Type.pp K.t) k);
    let ik = key_to_inner_key k in
    let iv = val_to_inner_val va in
    L.with_lock db.lock k (fun () ->
    set_and_list db ik iv @@ key_to_inner_val k)
    >>= fun () -> W.notify db.watches k (Some va)

  type watch = W.watch

  let watch db = W.watch db.watches
  let watch_key db = W.watch_key db.watches
  let unwatch db = W.unwatch db.watches

  let opt_equal f x y = match x, y with
    | None  ,  None  -> true
    | Some x, Some y -> f x y
    | _ -> false

  (* XXX With autoflush, this might flush some data without finishing the insert *)
  let test_and_set db k ~test ~set =
    Log.debug (fun m -> m "RW.test_and_set -> %a" (Irmin.Type.pp K.t) k);
    let ik = key_to_inner_key k in
    let root = db_root db in
    let test = match test with
    |Some va -> Some (val_to_inner_val va)
    |None -> None in
    L.with_lock db.lock k (fun () ->
      Stor.lookup root @@ ik >>= function v0 ->
      if opt_equal Stor.value_equal v0 test then begin
        match set with
        |Some va ->
            set_and_list db ik (val_to_inner_val va) @@ key_to_inner_val k
        |None ->
            may_autoflush db (fun () ->
              Stor.insert root ik @@ Stor.value_of_string "")
      end >>= fun () -> Lwt.return_true
      else Lwt.return_false
    ) >>= fun updated -> begin
      if updated then W.notify db.watches k set else Lwt.return_unit
    end >>= fun () -> Lwt.return updated

  let remove db k =
    Log.debug (fun l -> l "RW.remove %a" (Irmin.Type.pp K.t) k);
    let ik = key_to_inner_key k in
    let va = Stor.value_of_string "" in
    let root = db_root db in
    L.with_lock db.lock k (fun () ->
        may_autoflush db (fun () ->
            Stor.insert root ik va)) >>= fun () ->
    W.notify db.watches k None

  let list db =
    Log.debug (fun l -> l "RW.list");
    let root = db_root db in
    KeyHashtbl.fold (fun ik mk io ->
      io >>= function l ->
        Stor.mem root ik >>= function
          |true -> begin
            Stor.lookup root mk >>= function
              |None -> Lwt.fail @@ Failure "Missing metadata key"
              |Some iv -> Lwt.return @@ (key_of_inner_val iv) :: l
          end
          |false -> Lwt.return l
    ) db.keydata @@ Lwt.return []

  let find db k =
    Log.debug (fun l -> l "RW.find %a" (Irmin.Type.pp K.t) k);
    Stor.lookup (db_root db) @@ key_to_inner_key k >>= function
    |None -> Lwt.return_none
    |Some va -> Lwt.return_some @@ val_of_inner_val va

  let mem db k =
    Stor.mem (db_root db) @@ key_to_inner_key k
end

module Make (BC: BLOCK_CON) (PA: Wodan.SUPERBLOCK_PARAMS)
(M: Irmin.Metadata.S)
(C: Irmin.Contents.S)
(P: Irmin.Path.S)
(B: Irmin.Branch.S)
(H: Irmin.Hash.S)
= struct
  module DB = DB_BUILDER(BC)(PA)
  module AO = AO_BUILDER(BC)(PA)
  module RW = RW_BUILDER(BC)(PA)(H)
  include Irmin.Make(AO)(RW)(M)(C)(P)(B)(H)
  let flush = DB.flush
end

(* XXX Stable chunking or not? *)
module Make_chunked (BC: BLOCK_CON) (PA: Wodan.SUPERBLOCK_PARAMS)
(M: Irmin.Metadata.S)
(C: Irmin.Contents.S)
(P: Irmin.Path.S)
(B: Irmin.Branch.S)
(H: Irmin.Hash.S)
= struct
  module DB = DB_BUILDER(BC)(PA)
  module AO = Irmin_chunk.AO(AO_BUILDER(BC)(PA))
  module RW = RW_BUILDER(BC)(PA)(H)
  include Irmin.Make(AO)(RW)(M)(C)(P)(B)(H)
  let flush = DB.flush
end

module KV (BC: BLOCK_CON) (PA: Wodan.SUPERBLOCK_PARAMS) (C: Irmin.Contents.S)
= Make(BC)(PA)
  (Irmin.Metadata.None)
  (C)
  (Irmin.Path.String_list)
  (Irmin.Branch.String)
  (Irmin.Hash.SHA1)

module KV_git (BC: BLOCK_CON) (PA: Wodan.SUPERBLOCK_PARAMS)
= struct
  module DB = DB_BUILDER(BC)(PA)
  module LINK = LINK_BUILDER(BC)(PA)
  module AO = Irmin_chunk.AO_stable(LINK)(AO_BUILDER(BC)(PA))
  module RW = RW_BUILDER(BC)(PA)(Irmin.Hash.SHA1)
  include Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String)
  let flush = DB.flush
end

module KV_chunked (BC: BLOCK_CON) (PA: Wodan.SUPERBLOCK_PARAMS) (C: Irmin.Contents.S)
= Make_chunked(BC)(PA)
  (Irmin.Metadata.None)
  (C)
  (Irmin.Path.String_list)
  (Irmin.Branch.String)
  (Irmin.Hash.SHA1)
