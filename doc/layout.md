# Layout

## Blocks

Blocks are currently one of:
- the superblock, which is the first block at offset 0
- node blocks, representing serialized nodes
- unallocated blocks, which are generally ignored
when mounting (mounting starts with a bisect operation
that will look for the newest valid root and ignore blocks
that don't seem to belong to the filesystem; currently
this looks at the fsid, the crc, and the type flag
which must indicate a root).

There is also a special kind of unallocated block, which
looks like a root node block but is at generation zero
(considered invalid).
This is used to speed up bisection on freshly created filesystems.
The bisection considers these blocks valid as lower bounds,
but they are not valid root nodes.

## The superblock

```
(* 512 bytes.  The rest of the block isn't crc-controlled. *)
type%cstruct superblock = {
  magic : uint8_t; [@len 16]
  (* major version, all later fields may change if this does *)
  version : uint32_t;
  compat_flags : uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags : uint32_t;
  block_size : uint32_t;
  key_size : uint8_t;
  first_block_written : uint64_t;
  logical_size : uint64_t;
  (* FSID is UUID-sized (128 bits) *)
  fsid : uint8_t; [@len 16]
  reserved : uint8_t; [@len 443]
  crc : uint32_t;
}
[@@little_endian]
```

The focus is on managing compatibility.
This is written once at filesystem creation and never edited.

The magic string must be "MIRAGE KVFS \xf0\x9f\x90\xaa".

The major version must be 1.

Compat flags is currently empty, but may be added to without the
current implementation refusing to mount.

Incompat flags must currently contain the following, tracking
evolutions of the data layout:
- sb_incompat_rdepth; nodes now track their rdepth (which
  is their height, starting with leaves at 0)
- sb_incompat_fsid; all blocks now repeat the fsid to
  reduce risks of mixing two different filesystems or
  of parsing foreign or uninitialized data at the block
  level
- sb_incompat_value_count; nodes now mark the end of the value
  data area by keeping a count of values, instead of relying
  on the previous redzone mechanism

They may also contain the following optional flag:
- sb_incompat_tombstones; this affects semantics but not layout

Adding anything else to the incompat flags will prevent
the current implementation from mounting.
This is to prevent reading or writing newer formats that
are not compatible.

In the future, an sb_incompat_linear flag is considered for
indicating a linear (as opposed to circular and bisectable)
layout.

The block size defines how large blocks are and how to map
logical addresses (used for child pointers, from blocks to
other blocks) to physical addresses.

First block written points to the first block ever written
(generally an empty root), and is used to guide the bisection
process that finds the newest root.

Logical size says how large the filesystem is.  Resizing is not
supported in the current, circular layout.
The underlying device may grow, but the filesystem won't access
beyond its original logical size.

FSID is meant to uniquely identify a filesystem, and initialized
to cryptographically random bytes.

Reserved data is currently initialised to zero, but ignored when
mounting so that new fields aren't necessarily introducing
incompatible changes.

The CRC controls the first 512 bytes.  The first block may be larger than
the superblock; the extra padding behaves like reserved data, currently
initialised to zero but won't break mounting.

The block size must be a multiple of the IO size.
The IO size must match the page size which is the unit
for direct IO, on platforms that require direct IO.
The IO size must be a multiple of the sector size,
the size at which writes are atomic, which must be a
multiple of 512.

## Node blocks

There are two types of nodes: root and child.
A leaf is a child that doesn't have children;
there is no longer a special type marker or a specific layout for leaves.

The focus is on compacity and the ability to grow logged data and child data
independently.

```
type%cstruct anynode_hdr = {
  nodetype : uint8_t;
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t;
}
[@@little_endian]

type%cstruct rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype : uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t;
  depth : uint32_t;
}
[@@little_endian]

(* Contents: logged data, and child node links *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
 * crc *)

type%cstruct childnode_hdr = {
  (* nodetype = 2 *)
  nodetype : uint8_t;
  generation : uint64_t;
  fsid : uint8_t; [@len 16]
  value_count : uint32_t;
}
[@@little_endian]

(* Contents: logged data, and child node links *)
(* Layout: see above *)
```

All nodes start with a node type, a generation number,
a fsid identifying the filesystem, and a count of inline values.

The generation number uniquely identifies a block and its contents
on disk.  When the content changes, a new block is written at
another location with a new, greater generation number.
Children are written before the parents that reference them.
When a node has children, their generation number is strictly
lower.  This prevents loops.

All nodes end with a CRC (CRC32C) controlling the whole block.

Root nodes (nodetype: 1) are tree roots.

Child nodes have just the basic, generic header (nodetype, generation).
Root nodes also store their height (currently misnamed depth); this is
enough to compute the height (called rdepth in the code) of all nodes,
as well as ensure that all leaves are at depth zero.

Node content is made of two packed lists, one that grows towards higher
addresses and contains logged data, one that grows towards lower addresses
from just before the CRC and contains child data.  The latter is empty in
leaf nodes.

Logged data is made of contiguous logged items.  An item is a key followed
by a data size and the data itself (forming a length-prefixed, Pascal-style string).

Child data is made of contiguous child links.  A child link is a key followed
by the on-disk location of the child.  All-zeroes is not a valid representation
of a childlink, so the child data area ends either when running into
logged data, or when a run of zeroes is found when trying to load a childlink.
