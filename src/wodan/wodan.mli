(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
(*  Copyright 2019 Nicolas Assouad <nicolas@tarides.com>                          *)
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

exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC of int64
exception BadParams
exception ReadError
exception WriteError
exception OutOfSpace
exception NeedsFlush
(*exception BadKey of string*)
(*exception ValueTooLarge of string*)
exception BadNodeType of int

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK
  val discard: t -> int64 -> int64 -> (unit, write_error) result io
end

module BlockCompat : functor (B: Mirage_types_lwt.BLOCK) ->
  EXTBLOCK with type t = B.t

type insertable =
  |InsValue of string
  |InsChild of int64 * int64 option (* loc, alloc_id *)

val sizeof_superblock : int

val max_dirty : int

(* All parameters that can't be read from the superblock *)
type mount_options = {
  (* Whether the empty value should be considered a tombstone,
   * meaning that `mem` will return no value when finding it *)
  (* XXX Should this be a superblock flag? *)
  has_tombstone: bool;
  (* If enabled, instead of checking the entire filesystem when opening,
   * leaf nodes won't be scanned.  They will be scanned on open instead. *)
  fast_scan: bool;
  (* How many blocks to keep in cache *)
  cache_size: int;
}

(* All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  (* Size of blocks, in bytes *)
  val block_size: int
  (* The exact size of all keys, in bytes *)
  val key_size: int
end

module StandardSuperblockParams : SUPERBLOCK_PARAMS

val standard_mount_options : mount_options

val read_superblock_params : (module Mirage_types_lwt.BLOCK with type t = 'a) -> 'a -> (module SUPERBLOCK_PARAMS) Lwt.t

type deviceOpenMode = OpenExistingDevice | FormatEmptyDevice of int64

module type S = sig
  type disk
  type root

  module K : Wkey.S
  module V : Wvalue.S
  module P : SUPERBLOCK_PARAMS

  val key_of_cstruct : Cstruct.t -> K.t
  val key_of_string : string -> K.t
  val key_of_string_padded : string -> K.t
  val cstruct_of_key : K.t -> Cstruct.t
  val string_of_key : K.t -> string
  val next_key : K.t -> K.t

  val value_of_cstruct : Cstruct.t -> V.t
  val value_of_string : string -> V.t
  val value_equal : V.t -> V.t -> bool
  val cstruct_of_value : V.t -> Cstruct.t
  val string_of_value : V.t -> string
  
  val is_tombstone : root -> V.t -> bool
  val insert : root -> K.t -> V.t -> unit Lwt.t
  val lookup : root -> K.t -> V.t option Lwt.t
  val mem : root -> K.t -> bool Lwt.t
  val flush : root -> int64 Lwt.t
  val fstrim : root -> int64 Lwt.t
  val live_trim : root -> int64 Lwt.t
  val log_statistics : root -> unit
  val search_range : root -> K.t -> K.t -> (K.t -> V.t -> unit) -> unit Lwt.t
  val iter : root -> (K.t -> V.t -> unit) -> unit Lwt.t
  val prepare_io : deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
end

module Make :
  functor (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) -> S with type disk = B.t

type open_ret =
    OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

val open_for_reading :
  (module EXTBLOCK with type t = 'a) ->
  'a -> mount_options -> open_ret Lwt.t

