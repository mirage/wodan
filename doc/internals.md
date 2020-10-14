# Wodan internals

## Packages

### wodan

The wodan package is at the bottom of the package hierarchy
and implements the file-system, provided an abstract module
that does IO.

#### Implementation notes

There are data structures and utility methods defined at the top level.

There are cstructs defined for the layout of different types of blocks:
superblock, root node or child node. Additionally, an anynode cstruct contains
the fields common to root and child nodes.

The main data structures are a cache, containing a LRU, and LRU entries.

LRU entries are the in-memory representation of nodes.  Nodes contain and index
children and inline data.  The childlink can contain an alloc id if the child
has been loaded, which allows navigating the live tree.

The cache structure contains the LRU, a subtree for dirty nodes, various counters
which are used to allocate sequential numbers, counters used to track free
space, a map of where free space is on the filesystem, other counters used to
track statistics.

The main user-facing module is a Make functor, which takes a block device and a
set of parameters that control data layout.

The API contains the verbs:

- prepare_io for opening a device. Takes flags for either formatting an empty
device, or opening an existing filesystem. This returns a set of filesystem
roots indexed by their root id. Roots are references to a filesystem root.

- insert for inserting data into a root. Currently deleting is done by
inserting a zero-sized value.

- lookup for reading the value associated with a key within a root.

- flush for landing pending data on the disk.

Opening the filesystem involves locating the root block (using a bisection that
looks for the highest generation number of a root), checking the filesystem,
and scanning the entirety of if to establish a free space map. This will be
improved by maintaining a space map as part of a secondary metadata root.

The implementation for insert is split into a half that reserves space, might
rebalance the tree, might load nodes from disk, and a fast half that
immediately inserts into already available space. The reserve implementation is
sometimes called to reserve space for a batch of fast inserts; this is the case
when a node spills into a lower node. This split allows better error reporting
when there is no free space.

### wodan-unix

The wodan-unix package depends on Wodan and Unix,
so that the filesystem can be backed by standard files.

It contains a wodanc command, which is a multitool
that can create filesystems, dump and restore data
from/into filesystems, and trim unused blocks.

It can also run benchmarks, run other tests that
attempt to exercise most of the code base, and
fuzz the same tests.

### wodan-irmin

The wodan-irmin package provides some Irmin database types
that can be constructed from Wodan filesystems.
