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

val max_dirty : int

exception BadMagic

exception BadVersion

exception BadFlags

exception BadCRC of Location.t

exception BadParams

exception ReadError

exception WriteError

exception OutOfSpace

exception NeedsFlush

exception BadKey of string

exception ValueTooLarge of string

exception BadNodeType of int

(** The standard Mirage block signature, with Wodan-specific extensions *)
module type EXTBLOCK = sig
  include Mirage_block.S

  val discard : t -> int64 -> int64 -> (unit, write_error) result Lwt.t
end

(** Extend a basic Mirage block backend to provide Wodan-specific extensions

    This uses stub implementations which may be incomplete. *)
module BlockCompat (B : Mirage_block.S) : EXTBLOCK with type t = B.t

module AllocId : sig
  type t

  val zero : t

  val one : t

  val equal : t -> t -> bool

  val succ : t -> t

  val pp : Format.formatter -> t -> unit

  val hash : t -> int
end

val sizeof_superblock : int

type relax = {
  (* CRC errors ignored on any read where the magic CRC is used *)
  magic_crc : bool;
  (* Write non-superblock blocks with the magic CRC *)
  magic_crc_write : bool;
}

type mount_options = {
  (* XXX Should has_tombstone be a superblock flag? *)
  has_tombstone : bool;
      (** Whether the empty value should be considered a tombstone,
      meaning that `mem` will return no value when finding it *)
  fast_scan : bool;
      (** If enabled, instead of checking the entire filesystem when opening,
      leaf nodes won't be scanned.  They will be scanned on open instead. *)
  cache_size : int;  (** How many blocks to keep in cache *)
  relax : relax;  (** Integrity invariants to relax *)
}
(** All parameters that can't be read from the superblock *)

(** All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  val block_size : int
  (** Size of blocks, in bytes *)

  val key_size : int
  (** The exact size of all keys, in bytes *)
end

module Testing : sig
  val cstruct_cond_reset : Cstruct.t -> bool
end

module StandardSuperblockParams : SUPERBLOCK_PARAMS
(** Defaults for SUPERBLOCK_PARAMS *)

val standard_mount_options : mount_options
(** Defaults for mount_options *)

val read_superblock_params :
  (module Mirage_block.S with type t = 'a) ->
  'a ->
  relax ->
  (module SUPERBLOCK_PARAMS) Lwt.t

type deviceOpenMode =
  | OpenExistingDevice
  | FormatEmptyDevice of int64

module type S = sig
  type key
  (** An opaque type for fixed-size keys

      Conversion from/to strings is free *)

  type value
  (** An opaque type for bounded-size values

      Conversion from/to strings is free *)

  type disk
  (** A backing device *)

  type root
  (** A filesystem root *)

  (** Operations over keys *)
  module Key : sig
    type t = key

    val equal : t -> t -> bool

    val hash : t -> int

    val compare : t -> t -> int
  end

  module P : SUPERBLOCK_PARAMS
  (** The parameter module that was used to create this module *)

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
  (** The next highest key

      Raises Invalid_argument if already at the highest possible key *)

  val is_tombstone : root -> value -> bool
  (** Whether a value is a tombstone within a root *)

  val insert : root -> key -> value -> unit Lwt.t
  (** Store data in the filesystem

      Any previously stored value will be silently overwritten *)

  val lookup : root -> key -> value option Lwt.t
  (** Read data from the filesystem *)

  val mem : root -> key -> bool Lwt.t
  (** Check whether a key has been set within the filesystem *)

  val flush : root -> int64 Lwt.t
  (** Send changes to disk *)

  val fstrim : root -> int64 Lwt.t
  (** Discard all blocks which the filesystem doesn't explicitly use *)

  val live_trim : root -> int64 Lwt.t
  (** Discard blocks that have been unused since mounting
   or since the last live_trim call *)

  val log_statistics : root -> unit
  (** Send statistics about operations to the log *)

  val search_range : root -> key -> key -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the range from start inclusive to end_ exclusive

      Results are in no particular order. *)

  val iter : root -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the filesystem *)

  val prepare_io :
    deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
  (** Open a filesystem

      Returns a root and its generation number.
      When integrating Wodan as part of a distributed system,
      you may want to check here that the generation number
      has grown since the last flush *)
end

(** Build a Wodan.S module given a backing device and parameters

    This is the main entry point to Wodan. *)
module Make (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) : S with type disk = B.t

type open_ret =
  | OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

val open_for_reading :
  (module EXTBLOCK with type t = 'a) -> 'a -> mount_options -> open_ret Lwt.t
(** Open an existing Wodan filesystem, getting static parameters from the superblock *)
