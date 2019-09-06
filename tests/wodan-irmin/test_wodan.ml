(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

module BlockCon = struct
  include Ramdisk

  let connect name = Ramdisk.connect ~name

  let discard _ _ _ = Lwt.return (Ok ())
end

module DB_ram =
  Wodan_irmin.DB_BUILDER (BlockCon) (Wodan.StandardSuperblockParams)

(* let store = Irmin_test.store (module Wodan_irmin.Make(DB_ram)) (module Irmin.Metadata.None) *)
let store =
  ( module Wodan_irmin.KV_chunked (DB_ram) (Irmin.Contents.String)
  : Irmin_test.S )

let config = Wodan_irmin.config ~path:"disk.img" ~create:true ()

let clean () =
  let (module S : Irmin_test.S) = store in
  S.Repo.v config
  >>= fun repo ->
  S.Repo.branches repo >>= Lwt_list.iter_p (S.Branch.remove repo)

let init () = Nocrypto_entropy_lwt.initialize ()

let stats = None

let suite = {Irmin_test.name = "WODAN"; init; clean; config; store; stats}
