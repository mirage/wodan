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

module Log : Logs.LOG

val standard_mount_options : Wodan.mount_options

module Conf : sig
  val path : string Irmin.Private.Conf.key

  val create : bool Irmin.Private.Conf.key

  val cache_size : int Irmin.Private.Conf.key

  val fast_scan : bool Irmin.Private.Conf.key

  val list_key : string Irmin.Private.Conf.key

  val autoflush : bool Irmin.Private.Conf.key
end

val config :
  ?config:Irmin.config ->
  path:string ->
  create:bool ->
  ?cache_size:int ->
  ?fast_scan:bool ->
  ?list_key:string ->
  ?autoflush:bool ->
  unit ->
  Irmin.config

module type BLOCK_CON = sig
  include Wodan.EXTBLOCK

  val connect : string -> t io
end

module type DB = sig
  module Stor : Wodan.S

  type t

  val db_root : t -> Stor.root

  val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

  val v : Irmin.config -> t Lwt.t

  val flush : t -> int64 Lwt.t
end

module DB_BUILDER : functor (_ : BLOCK_CON) (_ : Wodan.SUPERBLOCK_PARAMS) ->
  DB

module CA_BUILDER : functor (_ : DB) -> Irmin.CONTENT_ADDRESSABLE_STORE_MAKER

module AO_BUILDER : functor (_ : DB) -> Irmin.APPEND_ONLY_STORE_MAKER

module AW_BUILDER : functor (_ : DB) (_ : Irmin.Hash.S) ->
  Irmin.ATOMIC_WRITE_STORE_MAKER

module Make
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) : sig
  module DB : DB

  include
    Irmin.S
      with type key = P.t
       and type step = P.step
       and type metadata = M.t
       and type contents = C.t
       and type branch = B.t
       and type hash = H.t

  val flush : DB.t -> int64 Lwt.t
end

module Make_chunked
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) : sig
  module DB : DB

  include
    Irmin.S
      with type key = P.t
       and type step = P.step
       and type metadata = M.t
       and type contents = C.t
       and type branch = B.t
       and type hash = H.t

  val flush : DB.t -> int64 Lwt.t
end

module KV (DB : DB) (C : Irmin.Contents.S) : sig
  module DB : DB

  include Irmin.KV with type contents = C.t

  val flush : DB.t -> int64 Lwt.t
end

module KV_git (DB : DB) : sig
  module DB : DB

  include Irmin.KV with type contents = Irmin.Contents.String.t

  val flush : DB.t -> int64 Lwt.t
end

module KV_chunked (DB : DB) (C : Irmin.Contents.S) : sig
  module DB : DB

  include Irmin.KV with type contents = C.t

  val flush : DB.t -> int64 Lwt.t
end
