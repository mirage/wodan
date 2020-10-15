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

To emit the correct error, Wodan has a function called reserve_dirty.
When an operation is about to dirty a node (which will propagate to
any parents that are still clean), sometimes creating child or sibling
nodes, it calls this function with the relevant info.
reserve_dirty computes how many nodes would be newly created or dirtied.
If the sum of both is below the count of free nodes, the operation
will not succeed as-is.
A second step can determine if it would work after flushing.
Flushing will turn any new or dirty nodes (prior to the operation)
into clean ones and reduce free space by the number of new nodes.
After this, the operation would dirty everything anew along the
node's parent path, and create new nodes as passed.
