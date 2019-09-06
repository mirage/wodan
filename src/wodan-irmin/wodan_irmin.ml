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

let src = Logs.Src.create "irmin.wodan"

module Log = (val Logs.src_log src : Logs.LOG)

let standard_mount_options =
  {Wodan.standard_mount_options with has_tombstone = true}

module Conf = struct
  let path =
    Irmin.Private.Conf.key ~doc:"Path to filesystem image" "path"
      Irmin.Private.Conf.string "wodan.img"

  let create =
    Irmin.Private.Conf.key ~doc:"Whether to create a fresh filesystem"
      "create" Irmin.Private.Conf.bool false

  let cache_size =
    Irmin.Private.Conf.key ~doc:"How many cache items to keep in the LRU"
      "cache_size" Irmin.Private.Conf.int 1024

  let fast_scan =
    Irmin.Private.Conf.key ~doc:"Whether to mount without scanning the leaves"
      "fast_scan" Irmin.Private.Conf.bool true

  let list_key =
    Irmin.Private.Conf.key
      ~doc:"A special key used to store metadata for listing other keys"
      "list_key" Irmin.Private.Conf.string "meta:keys-list:00000"

  let autoflush =
    Irmin.Private.Conf.key
      ~doc:
        "Whether to flush automatically when necessary for writes to go \
         through"
      "autoflush" Irmin.Private.Conf.bool false
end

let config ?(config = Irmin.Private.Conf.empty) ~path ~create ?cache_size
    ?fast_scan ?list_key ?autoflush () =
  let module C = Irmin.Private.Conf in
  let cache_size =
    match cache_size with
    | None -> C.default Conf.cache_size
    | Some cache_size -> cache_size
  in
  let fast_scan =
    match fast_scan with
    | None -> C.default Conf.fast_scan
    | Some fast_scan -> fast_scan
  in
  let list_key =
    match list_key with
    | None -> C.default Conf.list_key
    | Some list_key -> list_key
  in
  let autoflush =
    match autoflush with
    | None -> C.default Conf.autoflush
    | Some autoflush -> autoflush
  in
  C.add
    (C.add
       (C.add
          (C.add
             (C.add
                (C.add config Conf.autoflush autoflush)
                Conf.list_key list_key)
             Conf.fast_scan fast_scan)
          Conf.cache_size cache_size)
       Conf.path path)
    Conf.create create

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

  val v : Irmin.config -> t Lwt.t

  val flush : t -> int64 Lwt.t
end

module Cache (X : sig
  type config

  type t

  type key

  val v : config -> t Lwt.t

  val key : config -> key
end) : sig
  val read : X.config -> (X.config * X.t) Lwt.t
end = struct
  type key = X.key

  module Key = struct
    type t = key

    let hash = Hashtbl.hash

    let equal = ( = )
  end

  (* Weak in the values *)
  module ValueTab = Hashtbl.Make (Key)

  module Value = struct
    type t = X.t

    let hash = Hashtbl.hash

    let equal = ( == )
  end

  (* Weak in the keys *)
  module ConfigTab = Ephemeron.K1.Make (Value)

  let value_cache = ValueTab.create 10

  let config_cache = ConfigTab.create 10

  let find config =
    Gc.full_major ();
    let key = X.key config in
    try
      let weak_t = ValueTab.find value_cache key in
      let opt_t = Weak.get weak_t 0 in
      match opt_t with
      | None -> None
      | Some t ->
          let config' = ConfigTab.find config_cache t in
          Some (config', t)
    with Not_found -> None

  let add config t =
    let weak_t = Weak.create 1 in
    let key = X.key config in
    Weak.set weak_t 0 (Some t);
    Gc.finalise (fun _ -> ValueTab.remove value_cache key) t;
    ValueTab.add value_cache key weak_t;
    ConfigTab.add config_cache t config

  let read config =
    match find config with
    | Some v -> Lwt.return v
    | None -> X.v config >|= fun t -> add config t; (config, t)
end

module DB_BUILDER : functor (_ : BLOCK_CON) (_ : Wodan.SUPERBLOCK_PARAMS) ->
  DB =
functor
  (B : BLOCK_CON)
  (P : Wodan.SUPERBLOCK_PARAMS)
  ->
  struct
    module Stor = Wodan.Make (B) (P)

    type t = {
      root : Stor.root;
      autoflush : bool;
    }

    let db_root db = db.root

    let do_autoflush root op =
      try%lwt op ()
      with Wodan.NeedsFlush -> (
        Stor.flush root
        >>= function
        | _gen -> op () )

    let may_autoflush db op =
      if db.autoflush then do_autoflush db.root op else op ()

    let make ~path ~create ~mount_options ~autoflush =
      B.connect path
      >>= function
      | disk -> (
          B.get_info disk
          >>= function
          | info ->
              let open_arg =
                if create then
                  Wodan.FormatEmptyDevice
                    Int64.(
                      div
                        (mul info.size_sectors (of_int info.sector_size))
                        (of_int Wodan.StandardSuperblockParams.block_size))
                else Wodan.OpenExistingDevice
              in
              Stor.prepare_io open_arg disk mount_options
              >>= fun (root, _gen) -> Lwt.return {root; autoflush} )

    module Cache = Cache (struct
      type nonrec t = t

      type config = string * bool * Wodan.mount_options * bool

      type key = string

      let key (path, _, _, _) = path

      let v (path, create, mount_options, autoflush) =
        make ~path ~create ~mount_options ~autoflush
    end)

    let v config =
      let module C = Irmin.Private.Conf in
      let path = C.get config Conf.path in
      let create = C.get config Conf.create in
      let cache_size = C.get config Conf.cache_size in
      let fast_scan = C.get config Conf.fast_scan in
      let autoflush = C.get config Conf.autoflush in
      let mount_options =
        {standard_mount_options with fast_scan; cache_size}
      in
      Cache.read (path, create, mount_options, autoflush)
      >|= fun ((_, create', mount_options', autoflush'), t) ->
      assert (create = create');
      assert (mount_options = mount_options');
      assert (autoflush = autoflush');
      t

    let flush db = Stor.flush (db_root db)
  end

module CA_BUILDER : functor (DB : DB) ->
  Irmin.CONTENT_ADDRESSABLE_STORE_MAKER =
functor
  (DB : DB)
  (K : Irmin.Hash.S)
  (V : Irmin.Type.S)
  ->
  struct
    type 'a t = DB.t

    type key = K.t

    type value = V.t

    let () = assert (K.hash_size = DB.Stor.P.key_size)

    let find db k =
      Log.debug (fun l -> l "CA.find %a" (Irmin.Type.pp K.t) k);
      DB.Stor.lookup (DB.db_root db)
        (DB.Stor.key_of_string (Irmin.Type.to_bin_string K.t k))
      >>= function
      | None -> Lwt.return_none
      | Some v ->
          Lwt.return_some
            (Rresult.R.get_ok
               (Irmin.Type.of_bin_string V.t (DB.Stor.string_of_value v)))

    let mem db k =
      Log.debug (fun l -> l "CA.mem %a" (Irmin.Type.pp K.t) k);
      DB.Stor.mem (DB.db_root db)
        (DB.Stor.key_of_string (Irmin.Type.to_bin_string K.t k))

    let add db va =
      let raw_v = Irmin.Type.to_bin_string V.t va in
      let k = K.hash (fun f -> f raw_v) in
      Log.debug (fun m ->
          m "CA.add -> %a (%d)" (Irmin.Type.pp K.t) k K.hash_size);
      (*Log.debug (fun m -> m "AO.add -> %a (%d) -> %a" (Irmin.Type.pp K.t) k K.hash_size (Irmin.Type.pp V.t) va);*)
      (*Log.debug (fun m -> m "AO.add -> %a (%d) -> %s" (Irmin.Type.pp K.t) k K.hash_size raw_v);*)
      let raw_k = Irmin.Type.to_bin_string K.t k in
      let root = DB.db_root db in
      DB.may_autoflush db (fun () ->
          DB.Stor.insert root
            (DB.Stor.key_of_string raw_k)
            (DB.Stor.value_of_string raw_v))
      >>= function
      | () -> Lwt.return k

    let unsafe_add db k va =
      let raw_v = Irmin.Type.to_bin_string V.t va in
      Log.debug (fun m ->
          m "CA.unsafe_add -> %a (%d)" (Irmin.Type.pp K.t) k K.hash_size);
      let raw_k = Irmin.Type.to_bin_string K.t k in
      let root = DB.db_root db in
      DB.may_autoflush db (fun () ->
          DB.Stor.insert root
            (DB.Stor.key_of_string raw_k)
            (DB.Stor.value_of_string raw_v))

    let v = DB.v

    let cast t = (t :> [`Read | `Write] t)

    let batch t f = f (cast t)

    let close _t = Lwt.return_unit
  end

module AO_BUILDER : functor (_ : DB) -> Irmin.APPEND_ONLY_STORE_MAKER =
functor
  (DB : DB)
  (K : Irmin.Type.S)
  (V : Irmin.Type.S)
  ->
  struct
    type 'a t = DB.t

    type key = K.t

    type value = V.t

    let find db k =
      Log.debug (fun l -> l "AO.find %a" (Irmin.Type.pp K.t) k);
      DB.Stor.lookup (DB.db_root db)
        (DB.Stor.key_of_string (Irmin.Type.to_bin_string K.t k))
      >>= function
      | None -> Lwt.return_none
      | Some v ->
          Lwt.return_some
            (Rresult.R.get_ok
               (Irmin.Type.of_bin_string V.t (DB.Stor.string_of_value v)))

    let mem db k =
      Log.debug (fun l -> l "AO.mem %a" (Irmin.Type.pp K.t) k);
      DB.Stor.mem (DB.db_root db)
        (DB.Stor.key_of_string (Irmin.Type.to_bin_string K.t k))

    let add db k va =
      let raw_v = Irmin.Type.to_bin_string V.t va in
      let raw_k = Irmin.Type.to_bin_string K.t k in
      let root = DB.db_root db in
      DB.may_autoflush db (fun () ->
          DB.Stor.insert root
            (DB.Stor.key_of_string raw_k)
            (DB.Stor.value_of_string raw_v))

    let v = DB.v

    let cast t = (t :> [`Read | `Write] t)

    let batch t f = f (cast t)

    let close _t = Lwt.return_unit
  end

module AW_BUILDER : functor (_ : DB) (_ : Irmin.Hash.S) ->
  Irmin.ATOMIC_WRITE_STORE_MAKER =
functor
  (DB : DB)
  (H : Irmin.Hash.S)
  (K : Irmin.Type.S)
  (V : Irmin.Type.S)
  ->
  struct
    module BUILDER = DB
    module Stor = BUILDER.Stor
    module KeyHashtbl = Hashtbl.Make (Stor.Key)
    module W = Irmin.Private.Watch.Make (K) (V)
    module L = Irmin.Private.Lock.Make (K)

    type t = {
      nested : BUILDER.t;
      keydata : Stor.key KeyHashtbl.t;
      mutable magic_key : Stor.key;
      watches : W.t;
      lock : L.t;
    }

    let db_root db = BUILDER.db_root db.nested

    let may_autoflush db = BUILDER.may_autoflush db.nested

    let () = assert (H.hash_size = Stor.P.key_size)

    type key = K.t

    type value = V.t

    let key_to_inner_key k =
      Stor.key_of_string
        (Irmin.Type.to_bin_string H.t
           (H.hash (fun f -> f (Irmin.Type.to_bin_string K.t k))))

    let val_to_inner_val va =
      Stor.value_of_string (Irmin.Type.to_bin_string V.t va)

    let key_to_inner_val k =
      Stor.value_of_string (Irmin.Type.to_bin_string K.t k)

    let key_of_inner_val va =
      Rresult.R.get_ok
        (Irmin.Type.of_bin_string K.t (Stor.string_of_value va))

    let val_of_inner_val va =
      Rresult.R.get_ok
        (Irmin.Type.of_bin_string V.t (Stor.string_of_value va))

    let inner_val_to_inner_key va =
      Stor.key_of_string
        (Irmin.Type.to_bin_string H.t
           (H.hash (fun f -> f (Stor.string_of_value va))))

    let make ~list_key ~config =
      let%lwt db = BUILDER.v config in
      let root = BUILDER.db_root db in
      let magic_key = Bytes.make H.hash_size '\000' in
      Bytes.blit_string list_key 0 magic_key 0 (String.length list_key);
      let db =
        {
          nested = db;
          keydata = KeyHashtbl.create 10;
          magic_key = Stor.key_of_string (Bytes.unsafe_to_string magic_key);
          watches = W.v ();
          lock = L.v ();
        }
      in
      ( try%lwt
          while%lwt true do
            Stor.lookup root db.magic_key
            >>= function
            | None -> Lwt.fail Exit
            | Some va ->
                let ik = inner_val_to_inner_key va in
                KeyHashtbl.add db.keydata ik db.magic_key;
                db.magic_key <- Stor.next_key db.magic_key;
                Lwt.return_unit
          done
        with Exit -> Lwt.return_unit )
      >|= fun () -> db

    module Cache = Cache (struct
      type nonrec t = t

      type config = string * string * Irmin.Private.Conf.t

      type key = string

      let key (path, _, _) = path

      let v (_, list_key, config) = make ~list_key ~config
    end)

    let v config =
      let module C = Irmin.Private.Conf in
      let list_key = C.get config Conf.list_key in
      let path = C.get config Conf.path in
      Cache.read (path, list_key, config)
      >|= fun ((_, list_key', _), t) ->
      assert (list_key = list_key');
      t

    let set_and_list db ik iv ikv =
      assert (not (Stor.is_tombstone (db_root db) iv));
      ( if not (KeyHashtbl.mem db.keydata ik) then (
        KeyHashtbl.add db.keydata ik db.magic_key;
        may_autoflush db (fun () -> Stor.insert (db_root db) db.magic_key ikv)
        >>= fun () ->
        db.magic_key <- Stor.next_key db.magic_key;
        Lwt.return_unit )
      else Lwt.return_unit )
      >>= fun () ->
      may_autoflush db (fun () -> Stor.insert (db_root db) ik iv)

    let set db k va =
      Log.debug (fun m -> m "AW.set -> %a" (Irmin.Type.pp K.t) k);
      let ik = key_to_inner_key k in
      let iv = val_to_inner_val va in
      L.with_lock db.lock k (fun () ->
          set_and_list db ik iv (key_to_inner_val k))
      >>= fun () -> W.notify db.watches k (Some va)

    type watch = W.watch

    let watch db = W.watch db.watches

    let watch_key db = W.watch_key db.watches

    let unwatch db = W.unwatch db.watches

    let opt_equal f x y =
      match (x, y) with
      | None, None -> true
      | Some x, Some y -> f x y
      | _ -> false

    (* XXX With autoflush, this might flush some data without finishing the insert *)
    let test_and_set db k ~test ~set =
      Log.debug (fun m -> m "AW.test_and_set -> %a" (Irmin.Type.pp K.t) k);
      let ik = key_to_inner_key k in
      let root = db_root db in
      let test =
        match test with
        | Some va -> Some (val_to_inner_val va)
        | None -> None
      in
      L.with_lock db.lock k (fun () ->
          Stor.lookup root ik
          >>= function
          | v0 ->
              if opt_equal Stor.value_equal v0 test then
                ( match set with
                | Some va ->
                    set_and_list db ik (val_to_inner_val va)
                      (key_to_inner_val k)
                | None ->
                    may_autoflush db (fun () ->
                        Stor.insert root ik (Stor.value_of_string "")) )
                >>= fun () -> Lwt.return_true
              else Lwt.return_false)
      >>= fun updated ->
      (if updated then W.notify db.watches k set else Lwt.return_unit)
      >>= fun () -> Lwt.return updated

    let remove db k =
      Log.debug (fun l -> l "AW.remove %a" (Irmin.Type.pp K.t) k);
      let ik = key_to_inner_key k in
      let va = Stor.value_of_string "" in
      let root = db_root db in
      L.with_lock db.lock k (fun () ->
          may_autoflush db (fun () -> Stor.insert root ik va))
      >>= fun () -> W.notify db.watches k None

    let list db =
      Log.debug (fun l -> l "AW.list");
      let root = db_root db in
      KeyHashtbl.fold
        (fun ik mk io ->
          io
          >>= function
          | l -> (
              Stor.mem root ik
              >>= function
              | true -> (
                  Stor.lookup root mk
                  >>= function
                  | None -> Lwt.fail (Failure "Missing metadata key")
                  | Some iv -> Lwt.return (key_of_inner_val iv :: l) )
              | false -> Lwt.return l ))
        db.keydata (Lwt.return [])

    let find db k =
      Log.debug (fun l -> l "AW.find %a" (Irmin.Type.pp K.t) k);
      Stor.lookup (db_root db) (key_to_inner_key k)
      >>= function
      | None -> Lwt.return_none
      | Some va -> Lwt.return_some (val_of_inner_val va)

    let mem db k = Stor.mem (db_root db) (key_to_inner_key k)

    let close _t = Lwt.return_unit
  end

module Make
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) =
struct
  module DB = DB
  module CA = CA_BUILDER (DB)
  module AW = AW_BUILDER (DB) (H)
  include Irmin.Make (CA) (AW) (M) (C) (P) (B) (H)

  let flush = DB.flush
end

(* XXX Stable chunking or not? *)
module Make_chunked
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) =
struct
  module CA = Irmin_chunk.Content_addressable (AO_BUILDER (DB))
  module DB = DB
  module AW = AW_BUILDER (DB) (H)
  include Irmin.Make (CA) (AW) (M) (C) (P) (B) (H)

  let flush = DB.flush
end

module KV (DB : DB) (C : Irmin.Contents.S) =
  Make (DB) (Irmin.Metadata.None) (C) (Irmin.Path.String_list)
    (Irmin.Branch.String)
    (Irmin.Hash.SHA1)

module KV_git (DB : DB) = struct
  module DB = DB

  (*module AO = AO_BUILDER(DB)*)
  (*module AO = Irmin_chunk.AO(AO_BUILDER(DB))*)
  module CA = Irmin_chunk.Content_addressable (AO_BUILDER (DB))
  module AW = AW_BUILDER (DB) (Irmin.Hash.SHA1)
  include Irmin_git.Generic_KV (CA) (AW) (Irmin.Contents.String)

  let flush = DB.flush
end

module KV_chunked (DB : DB) (C : Irmin.Contents.S) =
  Make_chunked (DB) (Irmin.Metadata.None) (C) (Irmin.Path.String_list)
    (Irmin.Branch.String)
    (Irmin.Hash.SHA1)
