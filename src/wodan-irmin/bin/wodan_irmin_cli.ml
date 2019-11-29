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

open Irmin_unix

module RamBlockCon = struct
  include Ramdisk

  let connect name = Ramdisk.connect ~name

  let discard _ _ _ = Lwt.return (Ok ())
end

module DB_ram =
  Wodan_irmin.DB_BUILDER (RamBlockCon) (Wodan.StandardSuperblockParams)

module FileBlockCon = struct
  include Block

  let connect name = Block.connect name
end

module DB_fs =
  Wodan_irmin.DB_BUILDER (FileBlockCon) (Wodan.StandardSuperblockParams)

let _ =
  Resolver.Store.add "wodan-mem" (fun contents ->
      Resolver.Store.v ?remote:None
        (module Wodan_irmin.KV (DB_ram) ((val contents)) : Irmin.S));
  Resolver.Store.add "wodan" ~default:true (fun contents ->
      Resolver.Store.v ?remote:None
        (module Wodan_irmin.KV (DB_fs) ((val contents)) : Irmin.S))

let () = Cli.(run ~default commands)
