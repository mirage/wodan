# Free space management

## ENOSPC

The API ensures that flush can be called at all times,
unless the generation limit has been reached.

If an operation would succeed in-memory but would be impossible
to flush, an error is returned and the operation is not performed.
The actual error can be used to discriminate two cases:

- NeedsFlush means that the operation would succeed if a flush is
performed immediately before the operation is attempted again.
- OutOfSpace means that the operation will not succeed after
such a flush is performed.

To emit the correct error, Wodan needs to be able to simulate the
effects of a flush (free space is decremented by the pending
count of new nodes), and the effect of the operation that would
be run after the flush (nodes are created or dirtied; the operation
runs against a blank slate where all flushdata is already zero).

