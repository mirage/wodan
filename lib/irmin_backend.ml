open Lwt.Infix

module Conf = struct
  let path =
    Irmin.Private.Conf.key ~doc:"Path to filesystem image" "path"
      Irmin.Private.Conf.string "wodan.img"

  let create =
    Irmin.Private.Conf.key ~doc:"Whether to create a fresh filesystem" "create"
      Irmin.Private.Conf.bool false

  let lru_size =
    Irmin.Private.Conf.key ~doc:"How many cache items to keep in the LRU" "lru_size"
      Irmin.Private.Conf.int 1024
end

let config ?(config=Irmin.Private.Conf.empty) ~path ~create ?lru_size () =
  let module C = Irmin.Private.Conf in
  let lru_size = match lru_size with
  |None -> C.default Conf.lru_size
  |Some lru_size -> lru_size
  in
  C.add (C.add (C.add config Conf.lru_size lru_size) Conf.path path) Conf.create create

module type ConnectableBlock = sig
  include Mirage_types_lwt.BLOCK
  (* XXX mirage-block-unix and mirage-block-ramdisk don't have the
   * exact same signature *)
  (*val connect : name:string -> t*)
  val connect : string -> t
end

module type OF_STRING = sig
  type t
  val of_string : string -> (t, [ `Msg of string ]) Result.result
end

module RO_BUILDER
: ConnectableBlock -> Storage.PARAMS -> functor (K: Irmin.Hash.S) -> functor (V: OF_STRING) -> sig
  include Irmin.RO
  module Stor : Storage.S
  val db_root : t -> Stor.root
  val v : Irmin.config -> t Lwt.t
end with type key = K.t and type value = V.t
= functor (B: ConnectableBlock) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: OF_STRING) ->
struct
  type key = K.t
  type value = V.t
  module Stor = Storage.Make(B)(P)
  type t = {
    root: Stor.root;
  }
  let db_root db = db.root

  let v config =
    let module C = Irmin.Private.Conf in
    let path = C.get config Conf.path in
    let create = C.get config Conf.create in
    let lru_size = C.get config Conf.lru_size in
    let disk = B.connect path in
    B.get_info disk >>= function info ->
    let open_arg = if create then
      Storage.FormatEmptyDevice Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)
    else Storage.OpenExistingDevice in
    Stor.prepare_io open_arg disk lru_size >>= fun (root, _gen) ->
    Lwt.return { root }

  let find db k =
    Stor.lookup db.root @@ Stor.key_of_cstruct @@ K.to_raw k >>= function
    |None -> Lwt.return_none
    |Some v -> Lwt.return_some
      @@ Rresult.R.get_ok @@ V.of_string @@ Stor.string_of_value v

  let mem db k =
    Stor.mem db.root @@ Stor.key_of_cstruct @@ K.to_raw k
end

module AO_BUILDER
: ConnectableBlock -> Storage.PARAMS -> Irmin.AO_MAKER
= functor (B: ConnectableBlock) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Contents.Raw) ->
struct
  include RO_BUILDER(B)(P)(K)(V)

  let add db va =
    let raw_v = V.raw va in
    let k = K.digest raw_v in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v >>=
      function () -> Lwt.return k
end

module LINK_BUILDER
: ConnectableBlock -> Storage.PARAMS -> Irmin.LINK_MAKER
= functor (B: ConnectableBlock) (P: Storage.PARAMS)
(K: Irmin.Hash.S) ->
struct
  include RO_BUILDER(B)(P)(K)(K)

  let add db k va =
    let raw_v = K.to_raw va in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v
end

