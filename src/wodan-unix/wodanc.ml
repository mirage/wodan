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

open Lwt.Infix
open Cmdliner

(* Arg, Manpage, Term *)

let _ = Printexc.record_backtrace true

module Unikernel1 = Unikernel.Client (Block)

let () = Logs.set_reporter (Logs.format_reporter ())

(*let () = Logs.set_level (Some Logs.Info)*)

(* Implementations *)

type copts = {disk : string}

let dump copts _prefix =
  Lwt_main.run
    ( Block.connect copts.disk
    >>= fun bl ->
    Nocrypto_entropy_lwt.initialize () >>= fun _nc -> Unikernel1.dump bl )

let restore copts =
  Lwt_main.run
    ( Block.connect copts.disk
    >>= fun bl ->
    Nocrypto_entropy_lwt.initialize () >>= fun _nc -> Unikernel1.restore bl )

let format copts key_size block_size =
  Lwt_main.run
    ( Block.connect copts.disk
    >>= fun bl ->
    Nocrypto_entropy_lwt.initialize ()
    >>= fun _nc -> Unikernel1.format bl key_size block_size )

let trim copts =
  Lwt_main.run
    ( Block.connect copts.disk
    >>= fun bl ->
    Nocrypto_entropy_lwt.initialize ()
    >>= fun _nc -> Unikernel1.trim bl >|= ignore )

let exercise copts block_size =
  Lwt_main.run
    ( Block.connect copts.disk
    >>= fun bl ->
    Nocrypto_entropy_lwt.initialize ()
    >>= fun _nc -> Unikernel1.exercise bl block_size >|= ignore )

let bench _copts =
  (* Unlike the other functions, don't run within Lwt
     Also ignore the disk in copts to use our own ramdisk *)
  Unikernel1.bench ()

let fuzz copts =
  (* Persistent mode disabled, results are not stable,
   maybe due to CRC munging. *)
  AflPersistent.run (fun () ->
      Lwt_main.run (Block.connect copts.disk >>= fun bl -> Unikernel1.fuzz bl))

let help _copts man_format cmds topic =
  match topic with
  | None -> `Help (`Pager, None) (* help about the program. *)
  | Some topic -> (
      let topics = "topics" :: cmds in
      let conv, _ = Arg.enum (List.rev_map (fun s -> (s, s)) topics) in
      match conv topic with
      | `Error e -> `Error (false, e)
      | `Ok t when t = "topics" ->
          List.iter print_endline topics;
          `Ok ()
      | `Ok t when List.mem t cmds -> `Help (man_format, Some t)
      | `Ok _t ->
          let page = ((topic, 7, "", "", ""), [`S topic; `P "Placeholder"]) in
          `Ok (Manpage.print man_format Format.std_formatter page) )

(* Options common to all commands *)

(* TODO: support ramdisks *)
let copts disk = {disk}

let copts_t =
  let docs = Manpage.s_common_options in
  let disk =
    let doc = "Disk to operate on." in
    Arg.(
      required & pos 0 (some string) None & info [] ~docv:"DISK" ~docs ~doc)
  in
  Term.(const copts $ disk)

(* Commands *)

let dump_cmd =
  let prefix =
    Arg.(value & pos 1 (some string) None & info [] ~docv:"PREFIX")
  in
  let doc = "dump filesystem to standard output" in
  let exits = Term.default_exits in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Dumps the current filesystem to standard output.\n\
        \        Format is base64-encoded tab-separated values.";
    ]
  in
  ( Term.(const dump $ copts_t $ prefix),
    Term.info "dump" ~doc ~sdocs:Manpage.s_common_options ~exits ~man )

let restore_cmd =
  let doc = "load filesystem contents from standard input" in
  let exits = Term.default_exits in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Loads dump output from standard input, inserts it\n\
        \         as filesystem contents.";
    ]
  in
  ( Term.(const restore $ copts_t),
    Term.info "restore" ~doc ~sdocs:Manpage.s_common_options ~exits ~man )

let format_cmd =
  let doc = "Use a key size of $(docv) bytes." in
  let key_size =
    Arg.(
      value
      & opt int Wodan.StandardSuperblockParams.key_size
      & info ["key-size"] ~docv:"BYTES" ~doc)
  in
  let doc = "Use a block size of $(docv) bytes." in
  let block_size =
    Arg.(
      value
      & opt int Wodan.StandardSuperblockParams.block_size
      & info ["block-size"] ~docv:"BYTES" ~doc)
  in
  let doc = "Format a zeroed filesystem" in
  let exits = Term.default_exits in
  let man =
    [
      `S Manpage.s_description;
      `P "Format a filesystem that has been zeroed beforehand.";
    ]
  in
  ( Term.(const format $ copts_t $ key_size $ block_size),
    Term.info "format" ~doc ~sdocs:Manpage.s_common_options ~exits ~man )

let trim_cmd =
  let doc = "Trim an existing filesystem" in
  let exits = Term.default_exits in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Discard unused blocks from an existing filesystem.\n\
        \         This scans the disk for in-use blocks and discards\n\
        \         the rest.";
    ]
  in
  ( Term.(const trim $ copts_t),
    Term.info "trim" ~doc ~sdocs:Manpage.s_common_options ~exits ~man )

let exercise_cmd =
  let block_size =
    Arg.(value & pos 1 (some int) None & info [] ~docv:"block_size")
  in
  let doc = "Create a fresh filesystem, exercise and fill it" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Create a fresh filesystem, exercise and fill it.\n\
        \         This creates a filesystem, runs a few pre-defined operations\n\
        \         and fills it with random data.";
    ]
  in
  ( Term.(const exercise $ copts_t $ block_size),
    Term.info "exercise" ~doc ~man )

let bench_cmd =
  let doc = "Run a standardised micro-benchmark" in
  let man =
    [
      `S Manpage.s_description;
      `P "Run a micro-benchmark that does bulk insertions without flushing.";
    ]
  in
  (Term.(const bench $ copts_t), Term.info "bench" ~doc ~man)

let fuzz_cmd =
  let doc = "Fuzz a filesystem" in
  let exits = Term.default_exits in
  let man =
    [
      `S Manpage.s_description;
      `P "Runs a few operations on a fuzzer-generated filesystem.";
    ]
  in
  ( Term.(const fuzz $ copts_t),
    Term.info "fuzz" ~doc ~sdocs:Manpage.s_common_options ~exits ~man )

let help_cmd =
  let topic =
    let doc = "The topic to get help on. `topics' lists the topics." in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
  in
  let doc = "display help about wodanc and wodanc subcommands" in
  let man =
    [
      `S Manpage.s_description;
      `P "Prints help about wodanc commands and other subjects...";
    ]
  in
  ( Term.(
      ret (const help $ copts_t $ Arg.man_format $ Term.choice_names $ topic)),
    Term.info "help" ~doc ~exits:Term.default_exits ~man )

let default_cmd =
  let doc = "CLI for Wodan filesystems" in
  let sdocs = Manpage.s_common_options in
  let exits = Term.default_exits in
  ( Term.(ret (const (fun _ -> `Help (`Pager, None)) $ copts_t)),
    Term.info "wodanc" ~doc ~sdocs ~exits )

let cmds =
  [
    restore_cmd;
    dump_cmd;
    format_cmd;
    trim_cmd;
    exercise_cmd;
    bench_cmd;
    fuzz_cmd;
    help_cmd;
  ]

let () = Term.(exit (eval_choice default_cmd cmds))
