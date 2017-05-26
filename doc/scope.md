
# Design targets

This document describes a flash friendly, functional, safe and flexible
filesystem library.

## Flash friendly and flash optimised

The primary target of this filesystem is a flash translation layer.
A secondary target is hybrid devices layered using a FTL (bcache and
bcachefs included).

Whenever possible, we pick a design that performs well on both raw flash and
SSDs.   For example, having a large block size means that the FTL's log is
largely bypassed (thanks to the switch/merge optimisation).

However, we take advantage of the FTL by assuming that it handles bad blocks.
Neither is rewriting old blocks to prevent decay handled in the filesystem
layer.  Support for bad blocks and refreshing old blocks could be added
(preventing decay is easy in the current design) but this is not a primary
goal.

The filesystem uses a block size that must be a multiple of the erase block
size of the underlying flash (between 256k and 4M), and, ideally, the exact
same size.
Using a multiple guarantees that there is no write amplification and that the
FTL's garbage collection can perform well.
Using the exact same block size guarantees that writes aren't amplified at the
filesystem level when nodes are split or when the library user does periodic
checkpointing in order to get data durability.
Larger block sizes (up to the cluster block size, around 16M) may be
advantageous in order to take full advantage of the FTL's internal parallelism,
however this is only useful at very high throughput and periodic checkpointing
should not be used in those cases.

Another characteristic that makes the filesystem flash-friendly is that writes
are evenly distributed over the device.  The only exception is the superblock,
which is the first block, and is written to exactly once.  The first write is
to a random location, and every write after that is sequential.  Once writes
wrap around to used blocks, they skip over them.

Resizing is not supported because it would interfere with the mount-time
operation of locating the root block (which needs monotonic generation
numbers for root nodes), or alternatively require large scale copying and
rewriting.

Thin provisioning may be supported in the future, with a garbage collection
feature that periodically batches and discards blocks that are not in use
(which also improves the performance of the FTL).

The flip side of being flash friendly is that the filesystem can be optimised
to take advantage of the performance characteristics of flash, such as fast
random read access.  Tree nodes are not required to be grouped according to
access patterns.

References

* http://codecapsule.com/2014/02/12/coding-for-ssds-part-6-a-summary-what-every-programmer-should-know-about-solid-state-drives/
* https://www.usenix.org/system/files/conference/inflow14/inflow14-yang.pdf

## Functional

On disk, the filesystem provides a functional key value map.

The main advantage of being functional is that this is flash-friendly: there
are no in-place rewrites.

We use hitchhiker trees, which minimise the write amplification functional
updates would cause by batching changes close to the root.

While there may be multiple roots referring to a subtree, only one of them is
valid at any point.  This is single ownership.  It simplifies tracking
whether a block on the disk is in use: once a block is written on disk, its
previous instance can be re-used.

With single ownership, the data structures in memory don't need to be
functionally updated.  We lose snapshot support, but this can be provided
by Irmin.

Mounting the filesystem provides a tree_id -> root map.

Most operations: read key, write key, search key interval, flush are done on a root.

## Consistent

The filesystem is such that loss of the backing device at any point will
keep its contents in a consistent state.

To prevent torn writes and corruption at the backing device level, every block
of data is written with a valid CRC32C.

To prevent out-of-order writes, a write barrier is issued before every write
of a root block on devices that support it, so that the contents referenced
by the root block are always available if the root block is.

On file-backed devices, barriers are harder, though [not
impossible](https://lwn.net/Articles/667788/ "see discussion").  Having
journaled data makes this unnecessary, at a performance cost.

## Verified

The filesystem is checked at mount time.

This guarantees that the filesystem checker code is maintained and matches
every implemented feature.

It also provides an opportunity to build in-memory data structures to help
with filesystem access, particularly write access and garbage collection.

Those data structures may later be serialised, in a way that doesn't increase
the io bandwidth unreasonably and allows for faster, unverified mounts, but
this is not a primary goal.  Those unverified mounts will help support large
filesystems and particularly hybrid devices.

A possible help with barrier-less writes to the filesystem would be locating
the newest root block that passes filesystem checks.  When an inconsistency is
detected, the search for a valid root block could continue immediately before
the newest block with an inconsistency.  Assuming the window for in-flight data
isn't too large, the newest valid root block should still be fairly recent.

Corruption of a rarely-updated leaf node (bitrot) cannot be corrected in such a way.
Having filesystem checks at mount time gives early warning that backups or a
higher-level redundancy mechanism should be used, increasing the chances that
the data may be recovered.

## Domain specific

The filesystem can be tailored for the target domain.

It provides a key->value map, within some constraints.

The filesystem has a fixed key size that is chosen by the user.
This allows a better fit for the target domain.  For example,
the key size can be large to allow perfect/cryptographic hashing.
Or, the key size can be much smaller, and the filesystem may be
used as a hash table with open addressing.  The user must then
check for collisions before inserting and must implement
collision handling such as robin hood hashing.

The block size is also chosen by the user (taking into account FTL
characteristics).

The value size is bounded, the limit is such that a key value pair must
fit into a single block after leaf overhead is taken into account.
Large values won't pack well into leaf nodes, so values should all be
either small or close to the maximum allowed.  Large values will also
force frequent leaf insertions, and performance will be closer to btree
characteristics rather than fractal/hitchhiker tree characteristics.

Layering a generic posix-ish filesystem over this might be left as an exercice
for the library user.  This filesystem is meant to be a good, efficient fit for
domain-specific storage, and genericity is not a design goal at this level.

## Tunable performance

Like the data layout, performance characteristics are user controlled.

A root node will be written every time its in-memory representation fills up.
Since that may take a while, the user may implement regular checkpoint
intervals so that the on-flash data isn't stale.  More frequent checkpointing
will cause write amplification, but not enough to overwhelm or wear out the
flash (which would otherwise be idle).  Flushing without checkpointing (no FUA
or fdatasync) is also an option.

Write order (ascending or descending logical addresses) could also be chosen
at filesystem creation time.  Descending addresses may allow for more
sequential checking in a bcache scenario.

## An Irmin backend

The filesystem can be used as an Irmin backend.

The layer immediately above it should be irmin-chunk, so that values are of
bounded size.  Irmin-chunk might be extended to do a compression pass.  It
could also be extended to provide deduplication by using content-defined
chunking.

At a minimum, this means providing an implementation of the AO_MAKER_RAW and
LINK_MAKER signatures.

## Other considerations

Tiering, parallelism (both of which involve splitting allocations into multiple
pools) could conceivably be added to the existing design, but aren't design
goals at the moment.  FTLs already take advantage of internal parallelism and
doing the same in another layer would simply fragment the write patterns.

Redundancy (raid and other uptime preserving mechanisms) is not a design goal,
and should be handled at a higher or lower level.
