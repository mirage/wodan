val max_dirty : int
exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC of int64
exception BadParams
exception ReadError
exception WriteError
exception OutOfSpace
exception NeedsFlush
exception BadKey of string
exception ValueTooLarge of string
exception BadNodeType of int

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK
  val discard: t -> int64 -> int64 -> (unit, write_error) result io
end

module BlockCompat : functor (B: Mirage_types_lwt.BLOCK) -> EXTBLOCK

type insertable =
  |InsValue of string
  |InsChild of int64 * int64 option (* loc, alloc_id *)

val sizeof_superblock : int

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
module type S =
  sig
    type key
    type value
    type disk
    type root
    module Key :
      sig
        type t = key
        val equal : t -> t -> bool
        val hash : t -> int
        val compare : t -> t -> int
      end
    module P : SUPERBLOCK_PARAMS
    val key_of_cstruct : Cstruct.t -> key
    val key_of_string : string -> key
    val cstruct_of_key : key -> Cstruct.t
    val string_of_key : key -> string
    val value_of_cstruct : Cstruct.t -> value
    val value_of_string : string -> value
    val value_equal : value -> value -> bool
    val cstruct_of_value : value -> Cstruct.t
    val string_of_value : value -> string
    val next_key : key -> key
    val is_tombstone : root -> value -> bool
    val insert : root -> key -> value -> unit Lwt.t
    val lookup : root -> key -> value option Lwt.t
    val mem : root -> key -> bool Lwt.t
    val flush : root -> int64 Lwt.t
    val fstrim : root -> int64 Lwt.t
    val live_trim : root -> int64 Lwt.t
    val log_statistics : root -> unit
    val search_range :
      root -> key -> key -> (key -> value -> unit) -> unit Lwt.t
    val iter :
      root -> (key -> value -> unit) -> unit Lwt.t
    val prepare_io : deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
  end
module Make :
  functor (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) -> (S with type disk = B.t)

type open_ret =
    OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

val open_for_reading :
  (module EXTBLOCK with type t = 'a) ->
  'a -> mount_options -> open_ret Lwt.t

