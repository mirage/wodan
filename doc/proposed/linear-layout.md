# Linear layout

This is a modification of the original circular layout.
The goal is to enable growth of the backing device,
making Wodan more convenient to use when the size of the
data isn't known in advance.

## Changes to the layout

Instead of allocating from a free space map, blocks are always
allocated after the previously allocated space.

When a block is replaced, once everything has been flushed and a
barrier issued, the previous position of the block is discarded
from the backing device.
For performance reasons, this can be deferred.

## Changes to backing device commands

There are two new commands (relative to what the circular layout uses)
which mirage-block has to support:
- discard, which will send a trim if the backing device is a block
device, or a FALLOC_FL_PUNCH_HOLE / F_PUNCHHOLE if the backing
device is a file on a Unix filesystem.
- grow, which will require extra space from the backing device.

Growing is already supported through `resize` (though it will likely
require extra support so that LVM or such can know to provide extra
blocks).
Discard currently isn't, although there is a pull request:
https://github.com/mirage/mirage-block-unix/pull/86

## Changes to Wodan commands

A new command is introduced to trim freed blocks.
This is user-triggered because it introduces latency.

## Changes to data structures

Instead of tracking a free space map to allocate from,
we track the size of the allocated space.

We also track recently freed blocks so that they can be trimmed
in a batch operation.  Instead of using a bit vector (that
can't grow), we use a HashMap or similar.

## Changes to the mount operation

The newest root is found by scanning from the end of the device.
This is instead of bisecting the device for the highest generation
number.

## Growth and initialisation

Depending on the backend, growing the device will either provide
zero-initialised data (regular file backend) or uninitialised data
(LVM, although this needs to be confirmed).
We will assume zero-initialised data for now.
If we have to deal with uninitialised data, we'll have two options:
discarding the new data (which will have a performance impact),
and extending the format to carry uuids on every node.
The latter change would be useful on its own for making filesystem
initialisation more fool-proof.

