module type STATISTICS = sig
  type t

  val pp : Format.formatter -> t -> unit

  val data : t -> Metrics.Data.t
end

module HighLevel = struct
  type t = {
    mutable inserts : int;
    mutable lookups : int;
    mutable range_searches : int;
    mutable iters : int;
  }

  let create () = {inserts = 0; lookups = 0; range_searches = 0; iters = 0}

  let pp fmt {inserts; lookups; range_searches; iters} =
    Format.fprintf fmt "Ops: %d inserts %d lookups %d range searches %d iters"
      inserts lookups range_searches iters

  let data t =
    let open Metrics in
    Data.v
      [
        int "inserts" t.inserts;
        int "lookups" t.lookups;
        int "range_searches" t.range_searches;
        int "iters" t.iters;
      ]
end

module LowLevel = struct
  type t = {
    mutable reads : int;
    mutable writes : int;
    mutable discards : int;
    mutable barriers : int;
    block_size : int;
  }

  let create block_size =
    {reads = 0; writes = 0; discards = 0; barriers = 0; block_size}

  let pp fmt {reads; writes; discards; barriers; _} =
    Format.fprintf fmt "Ops: %d reads %d writes %d discards %d barriers" reads
      writes discards barriers

  let data t =
    let open Metrics in
    Data.v
      [
        int "reads" t.reads;
        int "writes" t.writes;
        int "discards" t.discards;
        int "barriers" t.barriers;
      ]
end

module Amplification = struct
  type t = {
    mutable read_ops : float;
    mutable read_bytes : float;
    mutable write_ops : float;
    mutable write_bytes : float;
  }

  let build (hl : HighLevel.t) (ll : LowLevel.t) =
    {
      read_ops = Float.of_int hl.lookups /. Float.of_int ll.reads;
      (* next one would require tracking sizes of values read;
         including for mem which normally ignores it *)
      read_bytes = 0.;
      write_ops = Float.of_int hl.inserts /. Float.of_int ll.writes;
      (* next one would require tracking sizes of values written *)
      write_bytes = 0.;
    }

  let pp fmt {read_ops; read_bytes; write_ops; write_bytes} =
    Format.fprintf fmt "Amplification: R %f [%f] W %f [%f]" read_bytes read_ops
      write_bytes write_ops

  let data t =
    let open Metrics in
    Data.v
      [
        float "read_ops" t.read_ops;
        float "read_bytes" t.read_bytes;
        float "write_ops" t.write_ops;
        float "write_bytes" t.write_bytes;
      ]
end
