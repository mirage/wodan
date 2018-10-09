open Lwt.Infix
open Mirage_types_lwt

(** Common signature for http and https. *)
module type HTTP = Cohttp_lwt.S.Server

(* Logging *)
let http_src = Logs.Src.create "http" ~doc:"HTTP server"
module Http_log = (val Logs.src_log http_src : Logs.LOG)

module BlockCon = struct
  include Block (* from mirage-block-solo5 *)
  let discard _ _ _ = Lwt.return @@ Ok ()
end

module DB = Wodan_irmin.DB_BUILDER
  (BlockCon)(Wodan.StandardSuperblockParams)
module Wodan_Git_KV = Wodan_irmin.KV_git(DB)

module Dispatch (S: HTTP) = struct

  (* given a URI, find the appropriate file,
   * and construct a response with its contents. *)
  let rec dispatcher repo uri =
    match Uri.path uri with
    | "" | "/" -> dispatcher repo (Uri.with_path uri "README.md")
    | "/README.md" ->
      let headers = Cohttp.Header.init_with "Content-Type" "text/plain" in
      let body = "" in
      S.respond_string ~status:`OK ~body ~headers ()
    | _ ->
      S.respond_not_found ()

  let serve dispatch =
    let callback (_, cid) request _body =
      let uri = Cohttp.Request.uri request in
      let cid = Cohttp.Connection.to_string cid in
      Http_log.info (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      dispatch uri
    in
    let conn_closed (_,cid) =
      let cid = Cohttp.Connection.to_string cid in
      Http_log.info (fun f -> f "[%s] closing" cid);
    in
    S.make ~conn_closed ~callback ()

end

module HTTP
    (Time: Mirage_types_lwt.TIME)
    (Pclock: Mirage_types.PCLOCK)
    (Http: HTTP)
    (B: BLOCK)
= struct

  module D = Dispatch(Http)

  let start _time _clock http block =
    let http_port = Key_gen.http_port () in
    let tcp = `TCP http_port in
    let store_conf = Wodan_irmin.config ~path:"../git-import.img" ~create:false () in
    let http =
      Http_log.info (fun f -> f "listening on %d/TCP" http_port);
      Wodan_Git_KV.Repo.v store_conf
      >>= fun repo ->
      Http_log.info (fun f -> f "repo ready");
      http tcp @@ D.serve (D.dispatcher repo)
    in
    Lwt.join [ http ]

end
