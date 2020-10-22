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

(** The Wodan module allows access to Wodan filesystems

    The entry point is {!Wodan.Make}, which returns a {!Wodan.S} module
    supporting filesystem operations *)

(** This module is used to look at Wodan performance *)
module Statistics : sig
  (** A generic interface for statistics *)
  module type STATISTICS = sig
    type t

    val pp : Format.formatter -> t -> unit

    val data : t -> Metrics.Data.t
  end

  (** stats of high-level Wodan operations *)
  module HighLevel : sig
    (* A very reduced, read-only view *)
    include STATISTICS

    val create : unit -> t
  end

  (** Stats of operations on the backing store *)
  module LowLevel : sig
    (* A very reduced, read-only view *)
    type t = private {
      mutable reads : int;
      mutable writes : int;
      mutable discards : int;
      mutable barriers : int;
      block_size : int;
    }

    include STATISTICS with type t := t

    val create : int -> t
  end

  (** Stats of amplification between high-level and low-level operations *)
  module Amplification : sig
    include STATISTICS

    val build : HighLevel.t -> LowLevel.t -> t
  end
end

exception BadMagic
(** Raised when trying to open a superblock and it doesn't have the magic tag
    for Wodan filesystems *)

exception BadVersion
(** Raised when trying to open a superblock and it doesn't have a supported
    version for Wodan filesystems *)

exception BadFlags
(** Raised when trying to open a superblock and it sets must-support flags that
    this version doesn't support *)

exception BadCRC of int64
(** Raised when a block doesn't have the expected CRC

    The exception carries the logical offset of the block. *)

exception BadParams
(** Raised when {!SUPERBLOCK_PARAMS} passed to the Make functor don't match
    actual settings saved in the superblock *)

exception ReadError
(** Raised on IO failures reading a block *)

exception WriteError
(** Raised on IO failures writing a block *)

exception OutOfSpace
(** Raised when the filesystem doesn't have enough space to perform the
    operation *)

exception NeedsFlush
(** Raised when the filesystem doesn't have enough space to perform an
    operation that would be possible if pending operations were flushed first *)

exception BadKey of string
(** Raised when converting to a key is impossible, eg because the input doesn't
    have the expected length

    The exception carries the original input. *)

exception ValueTooLarge of string
(** Raised when converting to a value is impossible, because the input would
    not fit on a single block

    Note that Wodan expects the user to chunk values if arbitrary lengths are
    to be supported. See also {!Wodan_irmin}'s relationship to irmin-chunk.

    The exception carries the original input *)

exception BadNodeType of int
(** Raised when a block doesn't have a known and expected node type

    The exception carries the type tag that couldn't be handled. *)

(** The standard Mirage block signature, with Wodan-specific extensions *)
module type EXTBLOCK = sig
  include Mirage_block.S

  val discard : t -> int64 -> int64 -> (unit, write_error) result Lwt.t
end

(** Extend a basic Mirage block backend to provide Wodan-specific extensions

    This uses stub implementations which may be incomplete. *)
module BlockCompat (B : Mirage_block.S) : EXTBLOCK with type t = B.t

(** Extends an EXTBLOCK backend to keep track of low-level statistics *)
module BlockWithStats (B : EXTBLOCK) : sig
  include EXTBLOCK

  val v : B.t -> int -> t
  (** Build a high-level block device with stats from a low-devel block device
      and a block size in bytes *)

  val stats : t -> Statistics.LowLevel.t
end

val sizeof_superblock : int
(** A constant that represents the size of Wodan superblocks

    Will be a power of two and a multiple of a standard sector size *)

type relax = {
  magic_crc : bool;
      (** CRC errors ignored on any read where the magic CRC is used *)
  magic_crc_write : bool;  (** Write non-superblock blocks with the magic CRC *)
}
(** Flags representing integrity features that will be relaxed

    Passed at mount time through {!mount_options} *)

type mount_options = {
  fast_scan : bool;
      (** If enabled, instead of checking the entire filesystem when opening,
          leaf nodes won't be scanned. They will be scanned on open instead. *)
  cache_size : int;  (** How many blocks to keep in cache *)
  relax : relax;  (** Integrity invariants to relax *)
}
(** All parameters that can't be read from the superblock *)

(** Superblock flags that are supported but not required by this Wodan version *)
module OptionalSuperblockFlags : sig
  type t
  (** A set of flags *)

  val empty : t
  (** The empty set of flags *)

  val tombstones_enabled : t
  (** The flag for tombstone support

      If set, the empty value will be considered a tombstone, meaning that
      functions that query values (mem, lookup, iter, search_range…) will
      treat it as if there was no value.

      This enables optimisations on the write path, allowing tombstones to
      fully disappear from storage eventually *)

  val intersect : t -> t -> t
  (** Take two sets of flags, return the common subset *)
end

(** All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  val block_size : int
  (** Size of blocks, in bytes *)

  val key_size : int
  (** The exact size of all keys, in bytes *)

  val optional_flags : OptionalSuperblockFlags.t
  (** The set of optional superblock flags *)
end

(** Operations used when testing and fuzzing *)
module Testing : sig
  val cstruct_cond_reset : Cstruct.t -> bool
end

module StandardSuperblockParams : SUPERBLOCK_PARAMS
(** Defaults for {!SUPERBLOCK_PARAMS} *)

val standard_mount_options : mount_options
(** Defaults for {!mount_options} *)

val read_superblock_params :
  (module Mirage_block.S with type t = 'a) ->
  'a ->
  relax ->
  (module SUPERBLOCK_PARAMS) Lwt.t
(** Read static filesystem parameters

    These are set at creation time and recorded in the superblock. See
    {!open_for_reading} if all you need is to mount the filesystem. *)

type format_params = {
  logical_size : int64;
      (** The number of blocks, including the superblock, that are part of the
          filesystem *)
  preroots_interval : int64;
      (** The (maximum) interval between pre-roots. Pre-roots are used to
          ensure that bisection will not be slow on freshly-formatted devices. *)
}
(** Parameters passed when creating a filesystem *)

val default_preroots_interval : int64

(** Modes for opening a device, see {!S.prepare_io} *)
type deviceOpenMode =
  | OpenExistingDevice
      (** Open an existing device, read logical size from superblock *)
  | FormatEmptyDevice of format_params
      (** Format a device, which must contain only zeroes, and use the given
          format_params *)

(** Filesystem operations

    This module is specialized for a given set of superblock parameters, with
    key and value types also being specialized to match. *)
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

      Raises {!Invalid_argument} if already at the highest possible key *)

  val is_tombstone : value -> bool
  (** Whether a value is a tombstone *)

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
  (** Discard blocks that have been unused since mounting or since the last
      live_trim call *)

  val log_statistics : root -> unit
  (** Send statistics about operations to the log *)

  val stats : root -> Statistics.HighLevel.t
  (** Grab a snapshot of statistics about high-level operations *)

  val search_range : root -> key -> key -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the range from start inclusive
      to end_ exclusive

      Results are in no particular order. *)

  val iter : root -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the filesystem *)

  val prepare_io :
    deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
  (** Open a filesystem

      Returns a root and its generation number. When integrating Wodan as part
      of a distributed system, you may want to check here that the generation
      number has grown since the last flush *)
end

(** Build a {!Wodan.S} module given a backing device and parameters

    This is the main entry point to Wodan. {!open_for_reading} is another entry
    point, used when you have an existing filesystem and do not care about the
    superblock parameters. *)
module Make (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) : S with type disk = B.t

(** This is a type that packages together a {!Wodan.S} with an opened root and
    the generation number read when mounting *)
type open_ret =
  | OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret  (** *)

val open_for_reading :
  (module EXTBLOCK with type t = 'a) -> 'a -> mount_options -> open_ret Lwt.t
(** Open an existing Wodan filesystem, getting static parameters from the
    superblock *)
