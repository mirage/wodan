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

module Wodan_DB =
  Wodan_irmin.DB_BUILDER
    (struct
      include Block

      let connect name = Block.connect name
    end)
    (Wodan.StandardSuperblockParams)

module Wodan_nongit_S =
  Wodan_irmin.KV_chunked (Wodan_DB) (Irmin.Contents.String)
module Wodan_git_S = Wodan_irmin.KV_git (Wodan_DB)
module Wodan_S = Wodan_git_S

let wodan_config = Wodan_irmin.config ~path:"git-import.img" ~create:true ()

module Git_S = Irmin_unix.Git.FS.KV (Irmin.Contents.String)

(*let git_config = Irmin_git.config (Sys.getcwd ())*)
(* Use a repo that doesn't have submodules *)
let git_config = Irmin_git.config Sys.argv.(1)

module Wodan_sync = Irmin.Sync (Wodan_S)

module StrHash = Hashtbl.Make (struct
  include String

  let hash = Hashtbl.hash
end)

let run () =
  let%lwt () = Nocrypto_entropy_lwt.initialize () in
  Logs.info (fun m -> m "Loading Wodan repo");
  let%lwt wodan_repo = Wodan_S.Repo.v wodan_config in
  Logs.info (fun m -> m "Loading Git repo");
  let%lwt git_repo = Git_S.Repo.v git_config in
  Logs.info (fun m -> m "Loading Git master");
  let%lwt git_branch = Git_S.of_branch git_repo Sys.argv.(2) in
  Logs.info (fun m -> m "Converting Git to a remote");
  let remote = Irmin.remote_store (module Git_S) git_branch in
  Logs.info (fun m -> m "Loading Wodan master");
  let%lwt wodan_master = Wodan_S.master wodan_repo in
  Logs.info (fun m -> m "Fetching from Git into Wodan");
  let%lwt head_commit = Wodan_sync.fetch_exn wodan_master remote in
  match head_commit with
  | `Head commit ->
      let%lwt () = Wodan_S.Head.set wodan_master commit in
      let%lwt wodan_raw = Wodan_S.DB.v wodan_config in
      let%lwt _gen = Wodan_S.DB.flush wodan_raw in
      Lwt.return_unit
  | `Empty -> Lwt.return_unit

let () =
  Logs.set_reporter (Logs.format_reporter ());
  Logs.set_level (Some Logs.Info);
  Logs.info (fun m -> m "Pwd %s" (Sys.getcwd ()));
  Lwt_main.run (run ())
