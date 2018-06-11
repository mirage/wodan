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
exception BadKey of Cstruct.t
exception ValueTooLarge of Cstruct.t
exception BadNodeType of int

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK
  val discard: t -> int64 -> int64 -> (unit, write_error) result io
end

type insertable =
  |InsValue of Cstruct.t
  |InsChild of int64 * int64 option (* loc, alloc_id *)

module type PARAMS =
  sig
    val block_size : int
    val key_size : int
    val has_tombstone : bool
    val fast_scan: bool
  end
module StandardParams : PARAMS
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
    val is_tombstone : value -> bool
    val insert : root -> key -> value -> unit Lwt.t
    val lookup : root -> key -> value option Lwt.t
    val mem : root -> key -> bool Lwt.t
    val flush : root -> int64 Lwt.t
    val fstrim : root -> int64 Lwt.t
    val live_trim : root -> int64 Lwt.t
    val log_statistics : root -> unit
    val search_range :
      root ->
      (key -> bool) -> (key -> bool) -> (key -> value -> unit) -> unit Lwt.t
    val prepare_io : deviceOpenMode -> disk -> int -> (root * int64) Lwt.t
  end
module Make :
  functor (B : EXTBLOCK) (P : PARAMS) -> (S with type disk = B.t)
