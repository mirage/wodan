open Lwt.Infix
open Mirage_types_lwt

module type HTTP = Cohttp_lwt.S.Server
(** Common signature for http and https. *)

(* Logging *)
let http_src = Logs.Src.create "http" ~doc:"HTTP server"

module Http_log = (val Logs.src_log http_src : Logs.LOG)

module Dispatch (Store : Wodan.S) (S : HTTP) = struct
  let failf fmt = Fmt.kstrf Lwt.fail_with fmt

  let key = Store.key_of_string "12345678901234567890"

  let next_camel store =
    Store.lookup store key
    >>= function
    | Some counter ->
        let c = Int64.of_string (Store.string_of_value counter) in
        let c = Int64.succ c in
        Store.insert store key (Store.value_of_string (Int64.to_string c))
        >>= fun () -> Lwt.return c
    | None ->
        Store.insert store key (Store.value_of_string "1")
        >>= fun () -> Lwt.return 1L

  (* given a URI, find the appropriate file,
   * and construct a response with its contents. *)
  let rec dispatcher store uri =
    match Uri.path uri with
    | ""
     |"/" ->
        dispatcher store (Uri.with_path uri "index.html")
    | "/index.html" ->
        let headers = Cohttp.Header.init_with "Content-Type" "text/html" in
        next_camel store
        >>= fun counter ->
        let body =
          Fmt.strf
            {html|<html>
<body>
<pre>
                     ,,__
           ..  ..   / o._)                   .---.
          /--'/--\  \-'||        .----.    .'     '.
         /        \_/ / |      .'      '..'         '-.
       .'\  \__\  __.'.'     .'          ì-._
         )\ |  )\ |      _.'
        // \\ // \\
       ||_  \\|_  \\_
   mrf '--' '--'' '--'

       %Ld camels served!
</pre>
</body></html>
|html}
            counter
        in
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
  module B = Wodan.BlockCompat (B)
  module Store = Wodan.Make (B) (Wodan.StandardSuperblockParams)
  module D = Dispatch (Store) (Http)

  let rec periodic_flush store =
    Time.sleep_ns 30_000_000_000L
    >>= fun () -> Store.flush store >>= fun _gen -> periodic_flush store

  let start _time _clock http block =
    let http_port = Key_gen.http_port () in
    let tcp = `TCP http_port in
    let http =
      Http_log.info (fun f -> f "listening on %d/TCP" http_port);
      Store.prepare_io Wodan.OpenExistingDevice block
        Wodan.standard_mount_options
      >>= fun (store, _) ->
      Lwt.async (fun () -> periodic_flush store);
      Http_log.info (fun f -> f "store done");
      http tcp (D.serve (D.dispatcher store))
    in
    Lwt.join [http]
end
