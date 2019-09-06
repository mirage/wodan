open Lwt.Infix
open Mirage_types_lwt

module type HTTP = Cohttp_lwt.S.Server
(** Common signature for http and https. *)

(* Logging *)
let http_src = Logs.Src.create "http" ~doc:"HTTP server"

module Http_log = (val Logs.src_log http_src : Logs.LOG)

module BlockCon = struct
  (* from mirage-block-solo5 *)
  include Block

  let discard _ _ _ = Lwt.return (Ok ())
end

module DB = Wodan_irmin.DB_BUILDER (BlockCon) (Wodan.StandardSuperblockParams)
module Wodan_Git_KV = Wodan_irmin.KV_git (DB)

module Dispatch (S : HTTP) = struct
  (* given a URI, find the appropriate file,
   * and construct a response with its contents. *)
  let rec dispatcher repo uri =
    match Uri.path uri with
    | ""
     |"/" ->
        dispatcher repo (Uri.with_path uri "README.md")
    | "/README.md" ->
        let headers = Cohttp.Header.init_with "Content-Type" "text/plain" in
        Wodan_Git_KV.Head.list repo
        >>= fun commits ->
        List.iter
          (fun k ->
            Logs.debug (fun m -> m "Head %a" Wodan_Git_KV.Commit.pp_hash k))
          commits;
        Wodan_Git_KV.master repo
        >>= fun t ->
        Wodan_Git_KV.list t []
        >>= fun li ->
        List.iter (fun (k, _v) -> Logs.debug (fun m -> m "List %s" k)) li;
        Lwt.catch
          (fun () -> Wodan_Git_KV.get t ["counter-wodan"; "README.md"])
          (fun err ->
            Logs.debug (fun m -> m "L %a" Fmt.exn err);
            raise err)
        >>= fun contents ->
        let body = Irmin.Type.to_string Wodan_Git_KV.contents_t contents in
        S.respond_string ~status:`OK ~body ~headers ()
    | str when str.[0] = '/' ->
        let headers = Cohttp.Header.init_with "Content-Type" "text/plain" in
        let head = String.sub str 1 (pred (String.length str)) in
        let head = Irmin.Type.of_string Wodan_Git_KV.Commit.Hash.t head in
        let head =
          match head with
          | Error _ -> assert false
          | Ok x -> x
        in
        Wodan_Git_KV.Commit.of_hash repo head
        >>= fun commit ->
        let commit =
          match commit with
          | None -> assert false
          | Some x -> x
        in
        Wodan_Git_KV.of_commit commit
        >>= fun t ->
        Wodan_Git_KV.get t ["README.md"]
        >>= fun t ->
        let body = Irmin.Type.to_string Wodan_Git_KV.contents_t t in
        S.respond_string ~status:`OK ~body ~headers ()
    | _ -> S.respond_not_found ()

  let serve dispatch =
    let callback (_, cid) request _body =
      let uri = Cohttp.Request.uri request in
      let cid = Cohttp.Connection.to_string cid in
      Http_log.info (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      dispatch uri
    in
    let conn_closed (_, cid) =
      let cid = Cohttp.Connection.to_string cid in
      Http_log.info (fun f -> f "[%s] closing" cid)
    in
    S.make ~conn_closed ~callback ()
end

module HTTP
    (Time : Mirage_types_lwt.TIME)
    (Pclock : Mirage_types.PCLOCK)
    (Http : HTTP)
    (B : BLOCK) =
struct
  module D = Dispatch (Http)

  let start _time _clock http block =
    let http_port = Key_gen.http_port () in
    let tcp = `TCP http_port in
    let store_conf =
      Wodan_irmin.config ~path:"../git-import.img" ~create:false ()
    in
    let http =
      Http_log.info (fun f -> f "listening on %d/TCP" http_port);
      Wodan_Git_KV.Repo.v store_conf
      >>= fun repo ->
      Http_log.info (fun f -> f "repo ready");
      http tcp (D.serve (D.dispatcher repo))
    in
    Lwt.join [http]
end
