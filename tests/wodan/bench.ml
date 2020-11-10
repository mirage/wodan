(* Defaults:
  BENCH_NB_ENTRIES (10_000_000 for index, lowered to 1M here) entries, with key_size=32 and value_size=13 -> large *)

open Lwt.Infix

module SBParams = struct
  include Wodan.StandardSuperblockParams

  let key_size = 32

  (*let block_size = 64*1024*)
end

let key_size = SBParams.key_size

let value_size = 13

let entry_size = key_size + value_size

let ( // ) = Filename.concat

let random_char () = char_of_int (33 + Random.int 94)

let random_string string_size =
  String.init string_size (fun _i -> random_char ())

let replace_sampling_interval = ref 0

module Context = struct
  module Key = struct
    type t = string [@@deriving repr]

    let v () = random_string key_size

    let hash = Hashtbl.hash

    let hash_size = 30

    let encode s = s

    let decode s off = String.sub s off key_size

    let encoded_size = key_size

    let equal = String.equal
  end

  module Value = struct
    type t = string [@@deriving repr]

    let v () = random_string value_size

    let encode s = s

    let decode s off = String.sub s off value_size

    let encoded_size = value_size
  end
end

(* merge two Metrics.Data.t *)
let merge_data d1 d2 =
  let rec aux d = function
    | [] -> d
    | f :: fl -> aux (Metrics.Data.cons f d) fl
  in
  aux d1 (Metrics.Data.fields d2)

module Backing = Wodan.BlockWithStats (Block)
module Stor = Wodan.Make (Backing) (SBParams)

let make_bindings_pool nb_entries =
  Array.init nb_entries (fun _ ->
      let k = Stor.key_of_string (random_string key_size) in
      let v = Stor.value_of_string (random_string value_size) in
      (k, v))

let bindings_pool = ref [||]

let absent_bindings_pool = ref [||]

let sorted_bindings_pool = ref [||]

module Benchmark = struct
  type result = {
    time : float;
    ops_per_sec : float;
    mbs_per_sec : float;
    read_amplification_calls : float;
    read_amplification_size : float;
    write_amplification_calls : float;
    write_amplification_size : float;
  }
  [@@deriving yojson]

  let run ~nb_entries f stor backing =
    let t0 = Sys.time () in
    f stor () >>= fun () ->
    let time = Sys.time () -. t0 in
    let backing_stats = Backing.stats backing in
    (* XXX high-level data is not that useful when all calls are explicit in the bench suite *)
    let _stats_data =
      merge_data
        (Wodan.Statistics.HighLevel.data (Stor.stats stor))
        (Wodan.Statistics.LowLevel.data backing_stats)
    in

    let nb_entriesf = float_of_int nb_entries in
    let entry_sizef = float_of_int entry_size in
    let read_amplification_size =
      float_of_int (backing_stats.reads * backing_stats.block_size)
      /. (entry_sizef *. nb_entriesf)
    in
    let read_amplification_calls =
      float_of_int backing_stats.reads /. nb_entriesf
    in
    let write_amplification_size =
      float_of_int (backing_stats.writes * backing_stats.block_size)
      /. (entry_sizef *. nb_entriesf)
    in
    let write_amplification_calls =
      float_of_int backing_stats.writes /. nb_entriesf
    in
    let ops_per_sec = nb_entriesf /. time in
    let mbs_per_sec = entry_sizef *. nb_entriesf /. 1_048_576. /. time in
    Lwt.return
      {
        time;
        ops_per_sec;
        mbs_per_sec;
        read_amplification_calls;
        read_amplification_size;
        write_amplification_calls;
        write_amplification_size;
      }

  let pp_list times = String.concat "; " (List.map string_of_float times)

  let pp_result fmt result =
    Format.fprintf fmt
      "Total time: %f@\n\
       Operations per second: %f@\n\
       Mbytes per second: %f@\n\
       Read amplification in syscalls: %f@\n\
       Read amplification in bytes: %f@\n\
       Write amplification in syscalls: %f@\n\
       Write amplification in bytes: %f@\n"
      result.time result.ops_per_sec result.mbs_per_sec
      result.read_amplification_calls result.read_amplification_size
      result.write_amplification_calls result.write_amplification_size
end

(* from https://erratique.ch/software/logs/doc/Logs/index.html#ex1 *)
let stamp_tag : Mtime.span Logs.Tag.def =
  Logs.Tag.def "stamp" ~doc:"Relative monotonic time stamp" Mtime.Span.pp

let stamp c = Logs.Tag.(empty |> add stamp_tag (Mtime_clock.count c))

(* Switched to use Logs_fmt.pp_header, a valid format string,
   the default app/dst, and not show timestamps when no tag is given;
   minimal changes because this is clearly complex *)
let reporter () =
  let report _src level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let with_stamp h tags k ppf fmt =
      let stamp =
        match tags with
        | None -> None
        | Some tags -> Logs.Tag.find stamp_tag tags
      in
      match stamp with
      | None ->
          Format.kfprintf k ppf
            ("%a @[" ^^ fmt ^^ "@]@.")
            Logs_fmt.pp_header (level, h)
      | Some s ->
          Format.kfprintf k ppf
            ("%a[%a] @[" ^^ fmt ^^ "@]@.")
            Logs_fmt.pp_header (level, h) Mtime.Span.pp s
    in
    let ppf =
      if level = App then Format.std_formatter else Format.err_formatter
    in
    msgf @@ fun ?header ?tags fmt -> with_stamp header tags k ppf fmt
  in
  {Logs.report}

module Index = struct
  let write ?(with_flush = false) bindings rw =
    Lwt_list.iteri_s
      (fun i (k, v) ->
        let r = Stor.insert rw k v in
        if with_flush || i mod 250_000 = 0 then
          r >>= fun () -> Stor.flush rw >|= ignore
        else r)
      (Array.to_list bindings)

  let read bindings r =
    (* assert presence? *)
    Lwt_list.iter_s
      (fun (k, _) -> Stor.lookup r k >|= ignore)
      (Array.to_list bindings)

  let read_absent bindings r =
    (* assert absence? *)
    Lwt_list.iter_s
      (fun (k, _) -> Stor.lookup r k >|= ignore)
      (Array.to_list bindings)

  let write_random t () = write !bindings_pool t

  let write_seq t =
    Array.sort
      (fun a b ->
        String.compare
          (Stor.string_of_key (fst a))
          (Stor.string_of_key (fst b)))
      !sorted_bindings_pool;
    fun () -> write !sorted_bindings_pool t

  let write_sync t () = write ~with_flush:true !bindings_pool t

  let iter t () = Stor.iter t (fun _ _ -> ())

  let find_random t () = read !bindings_pool t

  let find_absent t () = read_absent !absent_bindings_pool t

  let run ~nb_entries ~root ~name ~fresh b =
    let path = root // name in
    let size = Int64.mul 1048576L 1024L in
    let sector_size = 512 in
    assert (Int64.(rem size (of_int sector_size) = 0L));
    let sectors = Int64.(div size (of_int sector_size)) in
    (try Unix.mkdir root 0o700 with Unix.Unix_error (EEXIST, _, _) -> ());
    let fd = Unix.openfile path [Unix.O_CREAT] 0o600 in
    Unix.close fd;
    (*Ramdisk.create ~name:path ~size_sectors:sectors ~sector_size >|= Result.get_ok >>= fun disk ->*)
    Block.connect path >>= fun disk ->
    Block.resize disk sectors >|= Result.get_ok >>= fun () ->
    Block.get_info disk >>= fun info ->
    assert (info.sector_size = sector_size);
    assert (info.size_sectors = sectors);
    assert (Int64.(rem size (of_int Stor.P.block_size)) = 0L);
    let block_count = Int64.(div size (of_int Stor.P.block_size)) in
    let disk = Backing.v disk Stor.P.block_size in
    Stor.prepare_io
      ( if fresh then
        Wodan.FormatEmptyDevice
          {
            logical_size = block_count;
            preroots_interval = Wodan.default_preroots_interval;
          }
      else Wodan.OpenExistingDevice )
      disk
      {Wodan.standard_mount_options with cache_size = 2048}
    >>= fun (stor, _gen) ->
    let result = Benchmark.run ~nb_entries b stor disk in
    Stor.flush stor >>= fun _gen -> result

  type suite_elt = {
    name : string;
    synopsis : string;
    readonly : bool;
    fresh : bool;
    benchmark : Stor.root -> unit -> unit Lwt.t;
    dependency : string option;
    speed : [ `Quick | `Slow ];
  }

  let suite =
    [
      {
        name = "replace_random";
        synopsis = "Replace in random order";
        readonly = false;
        fresh = true;
        benchmark = write_random;
        dependency = None;
        speed = `Quick;
      };
      {
        name = "replace_random_sync";
        synopsis = "Replace in random order with sync";
        readonly = false;
        fresh = true;
        benchmark = write_sync;
        dependency = None;
        speed = `Slow;
      };
      {
        name = "replace_increasing_keys";
        synopsis = "Replace in increasing order of keys";
        readonly = false;
        fresh = true;
        benchmark = write_seq;
        dependency = None;
        speed = `Slow;
      };
      {
        name = "iter_rw";
        synopsis = "[RW] Iter";
        readonly = false;
        fresh = false;
        benchmark = iter;
        dependency = Some "replace_random";
        speed = `Slow;
      };
      {
        name = "find_random_ro";
        synopsis = "[RO] Find in random order";
        readonly = true;
        fresh = false;
        benchmark = find_random;
        dependency = Some "replace_random";
        speed = `Quick;
      };
      {
        name = "find_random_rw";
        synopsis = "[RW] Find in random order";
        readonly = false;
        fresh = false;
        benchmark = find_random;
        dependency = Some "replace_random";
        speed = `Quick;
      };
      {
        name = "find_absent_ro";
        synopsis = "[RO] Find absent values";
        readonly = true;
        fresh = false;
        benchmark = find_absent;
        dependency = Some "replace_random";
        speed = `Slow;
      };
      {
        name = "find_absent_rw";
        synopsis = "[RW] Find absent values";
        readonly = false;
        fresh = false;
        benchmark = find_absent;
        dependency = Some "replace_random";
        speed = `Slow;
      };
    ]
end

let list_benches () =
  let pp_bench ppf b = Fmt.pf ppf "%s\t-- %s" b.Index.name b.synopsis in
  Index.suite |> Fmt.(pr "%a" (list ~sep:Fmt.(const string "\n") pp_bench))

let schedule p s =
  let todos = List.map fst in
  let init = ref (s |> List.map (fun b -> (p b.Index.name, b))) in
  let apply_dep s =
    let deps =
      s
      |> List.fold_left
           (fun acc (todo, b) ->
             if todo then
               match b.Index.dependency with
               | Some s -> s :: acc
               | None -> acc
             else acc)
           []
    in
    s |> List.map (fun (todo, b) -> (todo || List.mem b.Index.name deps, b))
  in
  let next = ref (apply_dep !init) in
  while todos !init <> todos !next do
    init := !next;
    next := apply_dep !init
  done;
  let r = List.filter fst !init |> List.map snd in
  r

type config = {
  key_size : int;
  value_size : int;
  nb_entries : int;
  log_size : int;
  seed : int;
  with_metrics : bool;
  sampling_interval : int;
  minimal_flag : bool;
}
[@@deriving yojson]

let pp_config fmt config =
  Format.fprintf fmt
    "Key size: %d@\n\
     Value size: %d@\n\
     Number of bindings: %d@\n\
     Log size: %d@\n\
     Seed: %d@\n\
     Metrics: %b@\n\
     Sampling interval: %d" config.key_size config.value_size config.nb_entries
    config.log_size config.seed config.with_metrics config.sampling_interval

let cleanup root =
  let files = ["data"; "log"; "lock"; "log_async"; "merge"] in
  List.iter
    (fun (b : Index.suite_elt) ->
      let dir = root // b.name // "index" in
      List.iter
        (fun file ->
          let file = dir // file in
          if Sys.file_exists file then Unix.unlink file)
        files)
    Index.suite

let init config =
  Printexc.record_backtrace true;
  Random.init config.seed;
  Lwt_main.run (Nocrypto_entropy_lwt.initialize ());
  if config.with_metrics then (
    Metrics.enable_all ();
    Metrics_gnuplot.set_reporter ();
    Metrics_unix.monitor_gc 0.1 );
  bindings_pool := make_bindings_pool config.nb_entries;
  if not config.minimal_flag then (
    absent_bindings_pool := make_bindings_pool config.nb_entries;
    sorted_bindings_pool := Array.copy !bindings_pool;
    replace_sampling_interval := config.sampling_interval )

let print fmt (config, results) =
  let pp_bench fmt (b, result) =
    Format.fprintf fmt "%s@\n    @[%a@]" b.Index.synopsis Benchmark.pp_result
      result
  in
  Format.fprintf fmt
    "Configuration:@\n    @[%a@]@\n@\nResults:@\n    @[%a@]@\n" pp_config
    config
    Fmt.(list ~sep:(any "@\n@\n") pp_bench)
    results

let print_json fmt (config, results) =
  let open Yojson.Safe in
  let obj =
    `Assoc
      [
        ("config", config_to_yojson config);
        ( "results",
          `List
            (List.map
               (fun (b, result) ->
                 `Assoc
                   [
                     ("name", `String b.Index.name);
                     ("metrics", Benchmark.result_to_yojson result);
                   ])
               results) );
      ]
  in
  pretty_print fmt obj

let get_suite_list minimal_flag =
  if minimal_flag then
    List.filter (fun bench -> bench.Index.speed = `Quick) Index.suite
  else Index.suite

let run filter root output seed with_metrics log_size nb_entries json
    sampling_interval minimal_flag =
  Memtrace.trace_if_requested ();
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (reporter ());
  Logs.set_level (Some Logs.Info);
  let config =
    {
      key_size;
      value_size;
      nb_entries;
      log_size;
      seed;
      with_metrics;
      sampling_interval;
      minimal_flag;
    }
  in
  cleanup root;
  init config;
  let current_suite = get_suite_list config.minimal_flag in
  let name_filter =
    match filter with
    | None -> fun _ -> true
    | Some re -> Re.execp re
  in
  let c = Mtime_clock.counter () in
  current_suite
  |> schedule name_filter
  |> List.map (fun (b : Index.suite_elt) ->
         let name =
           match b.dependency with
           | None -> b.name
           | Some name -> name
         in
         Logs.app (fun m ->
             m "Benching %s with %d entries" b.name nb_entries ~tags:(stamp c));
         let result =
           Lwt_main.run
             (Index.run ~nb_entries ~root ~name ~fresh:b.fresh b.benchmark)
         in
         (b, result))
  |> fun results ->
  let fmt =
    ( match output with
    | None -> stdout
    | Some filename -> open_out filename )
    |> Format.formatter_of_out_channel
  in
  Fmt.pf fmt "%a@." (if json then print_json else print) (config, results)

open Cmdliner

let env_var s = Arg.env_var ("BENCH_" ^ s)

let new_file =
  let parse s =
    match Sys.file_exists s && Sys.is_directory s with
    | false -> `Ok s
    | true -> `Error (Printf.sprintf "Error: `%s' is a directory" s)
  in
  (parse, Format.pp_print_string)

let regex =
  let parse s =
    try Ok Re.(compile @@ Pcre.re ~flags:[`ANCHORED] s) with
    | Re.Perl.Parse_error -> Error (`Msg "Perl-compatible regexp parse error")
    | Re.Perl.Not_supported -> Error (`Msg "unsupported regexp feature")
  in
  let print = Re.pp_re in
  Arg.conv (parse, print)

let name_filter =
  let doc =
    "A regular expression matching the names of benchmarks to run. For more \
     information about the regexp syntax, please visit \
     https://perldoc.perl.org/perlre.html#Regular-Expressions."
  in
  let env = env_var "NAME_FILTER" in
  Arg.(
    value
    & opt (some regex) None
    & info ["f"; "filter"] ~env ~doc ~docv:"NAME_REGEX")

let data_dir =
  let doc = "Set directory for the data files" in
  let env = env_var "DATA_DIR" in
  Arg.(value & opt dir "_bench" & info ["d"; "data-dir"] ~env ~doc)

let output =
  let doc = "Specify an output file where the results should be written" in
  let env = env_var "OUTPUT" in
  Arg.(value & opt (some new_file) None & info ["o"; "output"] ~env ~doc)

let seed =
  let doc = "The seed used to generate random data." in
  let env = env_var "SEED" in
  Arg.(value & opt int 0 & info ["s"; "seed"] ~env ~doc)

let metrics_flag =
  let doc = "Use Metrics; note that it has an impact on performance" in
  let env = env_var "WITH_METRICS" in
  Arg.(value & flag & info ["m"; "with-metrics"] ~env ~doc)

let log_size =
  let doc = "The log size of the index." in
  let env = env_var "LOG_SIZE" in
  Arg.(value & opt int 500_000 & info ["log-size"] ~env ~doc)

let nb_entries =
  let doc = "The number of bindings." in
  let env = env_var "NB_ENTRIES" in
  Arg.(value & opt int 1_000_000 & info ["nb-entries"] ~env ~doc)

let list_cmd =
  let doc = "List all available benchmarks." in
  (Term.(pure list_benches $ const ()), Term.info "list" ~doc)

let json_flag =
  let doc = "Output the results as a json object." in
  let env = env_var "JSON" in
  Arg.(value & flag & info ["j"; "json"] ~env ~doc)

let sampling_interval =
  let doc = "Sampling interval for the duration of replace operations." in
  let env = env_var "REPLACE_DURATION_SAMPLING_INTERVAL" in
  Arg.(value & opt int 10 & info ["sampling-interval"] ~env ~doc)

let minimal_flag =
  let doc = "Run a set of minimal benchmarks" in
  let env = env_var "MINIMAL" in
  Arg.(value & flag & info ["minimal"] ~env ~doc)

let cmd =
  let doc = "Run all the benchmarks." in
  ( Term.(
      const run
      $ name_filter
      $ data_dir
      $ output
      $ seed
      $ metrics_flag
      $ log_size
      $ nb_entries
      $ json_flag
      $ sampling_interval
      $ minimal_flag),
    Term.info "run" ~doc ~exits:Term.default_exits )

let () =
  let choices = [list_cmd] in
  Term.(exit @@ eval_choice cmd choices)
