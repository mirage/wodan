type t

val sizeof_superblock : int

(** All parameters that can be read from the superblock *)
module type PARAMS = sig
  val block_size : int
  (** Size of blocks, in bytes *)

  val key_size : int
  (** The exact size of all keys, in bytes *)
end

val read_params :
  t -> [`Ok of (module PARAMS) | `BadCRC | `BadFlags | `BadMagic | `BadVersion]

type info = {
  first_block_written : int64;
  logical_size : int64;
  fsid : string
}

val read :
  t ->
  (module PARAMS) ->
  [`Ok of info | `BadCRC | `BadFlags | `BadMagic | `BadParams | `BadVersion]

val format : t -> (module PARAMS) -> info -> unit

val read_from_disk :
  read_disk:(Cstruct.t -> (unit, _) result Lwt.t) ->
  [`Ok of t | `ReadError] Lwt.t

val write_to_disk :
  write_disk:(Cstruct.t -> (unit, _) result Lwt.t) ->
  (t -> unit) ->
  [`Ok of unit | `WriteError] Lwt.t
