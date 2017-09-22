open Lwt.Infix

module StandardParams = struct
  include Storage.StandardParams
  let has_tombstone = true
end

module Conf = struct
  let path =
    Irmin.Private.Conf.key ~doc:"Path to filesystem image" "path"
      Irmin.Private.Conf.string "wodan.img"

  let create =
    Irmin.Private.Conf.key ~doc:"Whether to create a fresh filesystem" "create"
      Irmin.Private.Conf.bool false

  let lru_size =
    Irmin.Private.Conf.key ~doc:"How many cache items to keep in the LRU"
      "lru_size"
      Irmin.Private.Conf.int 1024

  let list_key =
    Irmin.Private.Conf.key
      ~doc:"A special key used to store metadata for listing other keys"
      "list_key"
      Irmin.Private.Conf.string "meta:keys-list:00000"
end

let config ?(config=Irmin.Private.Conf.empty) ~path ~create ?lru_size ?list_key () =
  let module C = Irmin.Private.Conf in
  let lru_size = match lru_size with
  |None -> C.default Conf.lru_size
  |Some lru_size -> lru_size
  in
  let list_key = match list_key with
  |None -> C.default Conf.list_key
  |Some list_key -> list_key
  in
  C.add (C.add (C.add (C.add config Conf.list_key list_key)
    Conf.lru_size lru_size) Conf.path path) Conf.create create

module type BLOCK_CON = sig
  include Mirage_types_lwt.BLOCK
  (* XXX mirage-block-unix and mirage-block-ramdisk don't have the
   * exact same signature *)
  (*val connect : name:string -> t io*)
  val connect : string -> t Lwt.t
end

module type DB = sig
  module Stor : Storage.S
  type t
  val db_root : t -> Stor.root
  val v : Irmin.config -> t Lwt.t
end

module DB_BUILDER
: BLOCK_CON -> Storage.PARAMS -> DB
= functor (B: BLOCK_CON) (P: Storage.PARAMS) ->
struct
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
    B.connect path >>= function disk ->
    B.get_info disk >>= function info ->
    let open_arg = if create then
      Storage.FormatEmptyDevice Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)
    else Storage.OpenExistingDevice in
    Stor.prepare_io open_arg disk lru_size >>= fun (root, _gen) ->
    Lwt.return { root }
end

module RO_BUILDER
: BLOCK_CON -> Storage.PARAMS -> functor (K: Irmin.Hash.S) -> functor (V: Irmin.Contents.Conv) -> sig
  include Irmin.RO
  include DB with type t := t
end with type key = K.t and type value = V.t
= functor (B: BLOCK_CON) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Contents.Conv) ->
struct
  include DB_BUILDER(B)(P)
  type key = K.t
  type value = V.t

  let () = assert (K.digest_size = P.key_size)

  let find db k =
    Stor.lookup (db_root db) @@ Stor.key_of_cstruct @@ K.to_raw k >>= function
    |None -> Lwt.return_none
    |Some v -> Lwt.return_some
      @@ Rresult.R.get_ok @@ Irmin.Type.decode_cstruct V.t @@ Stor.cstruct_of_value v

  let mem db k =
    Stor.mem (db_root db) @@ Stor.key_of_cstruct @@ K.to_raw k
end

module AO_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.AO_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Contents.Conv) ->
struct
  include RO_BUILDER(B)(P)(K)(V)

  let add db va =
    let raw_v = Irmin.Type.encode_cstruct V.t va in
    let k = K.digest V.t va in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v >>=
      function () -> Lwt.return k
end

module LINK_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.LINK_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS) (K: Irmin.Hash.S) ->
struct
  include RO_BUILDER(B)(P)(K)(K)

  let add db k va =
    let raw_v = K.to_raw va in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v
end

module RW_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.Hash.S -> Irmin.RW_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS) (H: Irmin.Hash.S)
(K: Irmin.Contents.Conv) (V: Irmin.Contents.Conv) ->
struct
  module BUILDER = DB_BUILDER(B)(P)
  module Stor = BUILDER.Stor

  module KeyHashtbl = Hashtbl.Make(Stor.Key)
  module W = Irmin.Private.Watch.Make(K)(V)

  type t = {
    root: Stor.root;
    keydata: Stor.key KeyHashtbl.t;
    mutable magic_key: Stor.key;
    watches: W.t;
  }

  let db_root db = db.root

  let () = assert (H.digest_size = P.key_size)
  let () = assert P.has_tombstone

  type key = K.t
  type value = V.t

  let key_to_inner_key k = Stor.key_of_cstruct @@ H.to_raw @@ H.digest K.t k
  let val_to_inner_val va = Stor.value_of_cstruct @@ Irmin.Type.encode_cstruct V.t va
  let key_to_inner_val k = Stor.value_of_cstruct @@ Irmin.Type.encode_cstruct K.t k
  let key_of_inner_val va =
    Rresult.R.get_ok @@ Irmin.Type.decode_cstruct K.t @@ Stor.cstruct_of_value va
  let val_of_inner_val va =
    Rresult.R.get_ok @@ Irmin.Type.decode_cstruct V.t @@ Stor.cstruct_of_value va
  let inner_val_to_inner_key va =
    Stor.key_of_cstruct @@ H.to_raw @@ H.digest Irmin.Type.cstruct
    @@ Stor.cstruct_of_value va

  let v config =
    let module C = Irmin.Private.Conf in
    BUILDER.v config >>= function db ->
      let root = BUILDER.db_root db in
      let db = {
        root;
        keydata = KeyHashtbl.create 10;
        magic_key = Stor.key_of_string @@ C.get config Conf.list_key;
        watches = W.v ();
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
        end >>
          Lwt.return db

  let set_and_list db ik iv ikv =
    assert (not @@ Stor.is_tombstone iv);
    if not @@ KeyHashtbl.mem db.keydata ik then begin
      KeyHashtbl.add db.keydata ik db.magic_key;
      Stor.insert db.root db.magic_key ikv >>
      begin
        db.magic_key <- Stor.next_key db.magic_key;
        Stor.insert db.root ik iv
      end
    end else
      Stor.insert db.root ik iv

  let set db k va =
    let ik = key_to_inner_key k in
    let iv = val_to_inner_val va in
    set_and_list db ik iv @@ key_to_inner_val k >>
    W.notify db.watches k (Some va)

  type watch = W.watch

  let watch db = W.watch db.watches
  let watch_key db = W.watch_key db.watches
  let unwatch db = W.unwatch db.watches

  let test_and_set db k ~test ~set =
    let ik = key_to_inner_key k in
    let test = match test with
    |Some va -> Some (val_to_inner_val va)
    |None -> None in
    Stor.lookup (db_root db) @@ ik >>= function v0 ->
      if v0 = test then begin
        match set with
        |Some va ->
            set_and_list db ik (val_to_inner_val va) @@ key_to_inner_val k
        |None -> Stor.insert (db_root db) ik @@ Stor.value_of_string ""
      end >> W.notify db.watches k set >> Lwt.return_true
      else Lwt.return_false

  let remove db k =
    let ik = key_to_inner_key k in
    let va = Stor.value_of_string "" in
    Stor.insert (db_root db) ik va >>
    W.notify db.watches k None

  let list db =
    KeyHashtbl.fold (fun ik mk io ->
      io >>= function l ->
        Stor.mem db.root ik >>= function
          |true -> begin
            Stor.lookup db.root mk >>= function
              |None -> Lwt.fail @@ Failure "Missing metadata key"
              |Some iv -> Lwt.return @@ (key_of_inner_val iv) :: l
          end
          |false -> Lwt.return l
    ) db.keydata @@ Lwt.return []

  let find db k =
    Stor.lookup (db_root db) @@ key_to_inner_key k >>= function
    |None -> Lwt.return_none
    |Some va -> Lwt.return_some @@ val_of_inner_val va

  let mem db k =
    Stor.mem (db_root db) @@ key_to_inner_key k
end

module Make (BC: BLOCK_CON) (PA: Storage.PARAMS)
(M: Irmin.Metadata.S)
(C: Irmin.Contents.S)
(P: Irmin.Path.S)
(B: Irmin.Branch.S)
(H: Irmin.Hash.S)
= struct
  module AO = AO_BUILDER(BC)(PA)
  module RW = RW_BUILDER(BC)(PA)(H)
  include Irmin.Make(AO)(RW)(M)(C)(P)(B)(H)
end

module KV (BC: BLOCK_CON) (PA: Storage.PARAMS) (C: Irmin.Contents.S)
= Make(BC)(PA)
  (Irmin.Metadata.None)
  (C)
  (Irmin.Path.String_list)
  (Irmin.Branch.String)
  (Irmin.Hash.SHA1)

