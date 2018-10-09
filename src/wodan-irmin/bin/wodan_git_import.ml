(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
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


module Wodan_nongit_S = Wodan_irmin.KV_chunked
    (struct
      include Block
      let connect name = Block.connect name
    end)
    (Wodan.StandardSuperblockParams)
    (Irmin.Contents.String)

module Wodan_git_S = Wodan_irmin.KV_git
    (struct
      include Block
      let connect name = Block.connect name
    end)
    (Wodan.StandardSuperblockParams)

module Wodan_S = Wodan_git_S

let wodan_config = Wodan_irmin.config
    ~path:"git-import.img" ~create:true ()

module Git_S = Irmin_unix.Git.FS.KV(Irmin.Contents.String)

(*let git_config = Irmin_git.config @@ Sys.getcwd ()*)
(* Use a repo that doesn't have submodules *)
let git_config = Irmin_git.config Sys.argv.(1)

module Wodan_sync = Irmin.Sync(Wodan_S)

module StrHash = Hashtbl.Make(struct include String let hash=Hashtbl.hash end)
let persist_handles = StrHash.create 1

let run () =
  let%lwt () = Nocrypto_entropy_lwt.initialize () in
  let%lwt wodan_repo = Wodan_S.Repo.v wodan_config in
  StrHash.add persist_handles "keep it!" wodan_config;
  let%lwt git_repo = Git_S.Repo.v git_config in
  let%lwt git_master = Git_S.master git_repo in
  let remote = Irmin.remote_store (module Git_S) git_master in
  let%lwt wodan_master = Wodan_S.master wodan_repo in
  let%lwt _git_head = Git_S.Head.get git_master in
  let%lwt git_heads = Git_S.Head.list git_repo in
  begin
    List.iter
      (fun _commit ->
         Logs.info @@
         (*fun m -> m "Found a head: %a" Git_S.Commit.pp _commit)*)
         fun m -> m "Found a head")
      git_heads;
    begin if git_heads = [] then
      Logs.debug @@ fun m -> m "Found no head";
    end;
    let%lwt head_commit =
      Wodan_sync.fetch_exn wodan_master remote in
    let%lwt () = Wodan_S.Head.set wodan_master head_commit in
    let%lwt wodan_raw = Wodan_S.DB.v wodan_config in
    let%lwt _gen = Wodan_S.DB.flush wodan_raw in
    Logs.debug (fun m -> m "persist_handles %d" @@ StrHash.length persist_handles);
    Lwt.return_unit
  end

let () =
  Logs.set_reporter @@ Logs.format_reporter ();
  Logs.set_level @@ Some Logs.Info;
  Logs.debug @@ fun m -> m "Pwd %s" @@ Sys.getcwd ();
  Lwt_main.run @@ run ()

