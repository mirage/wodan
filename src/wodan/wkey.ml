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

[@@@warning "-32"]

module type S = sig
  type t = string

  exception BadKey of string

  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> int

  val zero_key : t
  val top_key : t

  val key_of_cstruct : Cstruct.t -> t
  val key_of_string : string -> t
  val key_of_string_padded : string -> t
  val cstruct_of_key : t -> Cstruct.t
  val string_of_key : t -> string
  val next_key : t -> t
end

module Make (P : Wblock.SUPERBLOCK_PARAMS) : S = struct
  type t = string

  exception BadKey of string

  let equal = String.equal
  let hash = Hashtbl.hash
  let compare = String.compare

  let zero_key = String.make P.key_size '\000'
  let top_key = String.make P.key_size '\255'


  let key_of_cstruct key =
    if Cstruct.len key <> P.key_size then
      raise @@ BadKey (Cstruct.to_string key)
    else
      Cstruct.to_string key
  
  let key_of_string key =
    if String.length key <> P.key_size then
      raise (BadKey key)
    else
      key
  let key_of_string_padded key =
    if String.length key > P.key_size then
      raise (BadKey key)
    else
      key ^ (String.make (P.key_size - String.length key) '\000')
  
  let cstruct_of_key key = Cstruct.of_string key

  let string_of_key key = key

  let next_key key =
    if key = top_key then
      raise (BadKey ("Already at top key : " ^ key))
    else
      let carry = ref 1 in
      String.map
        (fun c ->
          let c' = (!carry + Char.code c) mod 256 in
          carry := if c' = 0 then 1 else 0;
          Char.chr c')
        key
end