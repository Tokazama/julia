# This file is a part of Julia. License is MIT: https://julialang.org/license

const ThreadSynchronizer = GenericCondition{Threads.SpinLock}

# Advisory reentrant lock
"""
    Lock()

Creates a re-entrant lock for synchronizing [`Task`](@ref)s. The same task can
acquire the lock as many times as required. Each [`lock`](@ref) must be matched
with an [`unlock`](@ref).

Calling 'lock' will also inhibit running of finalizers on that thread until the
corresponding 'unlock'. Use of the standard lock pattern illustrated below
should naturally be supported, but beware of inverting the try/lock order or
missing the try block entirely (e.g. attempting to return with the lock still
held):

```
lock(l)
try
    <atomic work>
finally
    unlock(l)
end
```
"""
mutable struct Lock <: AbstractLock
    @atomic locked_by::Union{Task, Nothing}
    cond_wait::ThreadSynchronizer
    @atomic reentrancy_cnt::Int

    Lock() = new(nothing, ThreadSynchronizer(), 0)
end
const ReentrantLock = Lock

assert_havelock(l::ReentrantLock) = assert_havelock(l, l.locked_by)

"""
    islocked(lock) -> Status (Boolean)

Check whether the `lock` is held by any task/thread.
This should not be used for synchronization (see instead [`trylock`](@ref)).
"""
function islocked(rl::ReentrantLock)
    return rl.reentrancy_cnt != 0
end

"""
    trylock(lock) -> Success (Boolean)

Acquire the lock if it is available,
and return `true` if successful.
If the lock is already locked by a different task/thread,
return `false`.

Each successful `trylock` must be matched by an [`unlock`](@ref).
"""
@inline function trylock(rl::ReentrantLock)
    ct = current_task()
    if ct === rl.locked_by
        @atomic :monotonic rl.reentrancy_cnt = rl.reentrancy_cnt + 1
        return true
    end
    if rl.locked_by === nothing
        GC.disable_finalizers()
        if (@atomicreplace rl.locked_by nothing => ct).success
            @atomic :monotonic rl.reentrancy_cnt = 1
            return true
        end
        GC.enable_finalizers()
    end
    return false
end

"""
    lock(lock)

Acquire the `lock` when it becomes available.
If the lock is already locked by a different task/thread,
wait for it to become available.

Each `lock` must be matched by an [`unlock`](@ref).
"""
function lock(rl::ReentrantLock)
    ct = current_task()
    if !trylock(rl)
        c = rl.cond_wait
        lock(c.lock)
        try
            # Implements this, but race-free, while avoiding adding an extra
            # bit to the Lock struct to indicate the presence of waiters.
            #   while !trylock(rl)
            #       wait(rl.cond_wait)
            #   end
            while true
                _wait2(c, ct)
                if trylock(rl)
                    # This removes it from _wait2 again.
                    # Note that we hold the lock on c, so we know the list
                    # cannot have changed even while the other thread might
                    # have checked `isempty`, and is now waiting on this lock.
                    list_deletefirst!(c.waitq, ct)
                    break
                end
                token = unlockall(c.lock)
                try
                    wait()
                catch
                    ct.queue === nothing || list_deletefirst!(ct.queue, ct)
                    rethrow()
                finally
                    relockall(c.lock, token)
                end
            end
        finally
            unlock(c.lock)
        end
    end
    return
end

"""
    unlock(lock)

Releases ownership of the `lock`.

If this is a recursive lock which has been acquired before, decrement an
internal counter and return immediately.
"""
function unlock(rl::ReentrantLock)
    ct = current_task()
    n = rl.reentrancy_cnt
    rl.locked_by === ct || error(n == 0 ? "unlock count must match lock count" : "unlock from wrong thread")
    # n == 0 && error("unlock count must match lock count") # impossible
    @atomic :monotonic rl.reentrancy_cnt = n - 1
    if n == 1
        # either our thread will release locked_by first,
        # or the other thread will be added to waitq first
        # so we avoid the race, and usually the lock
        @atomic rl.locked_by = nothing # TODO: make this :release?
        # FIXME: Core.Intrinsics.atomic_fence(:acquire)
        if !isempty(rl.cond_wait.waitq) # TODO: make this :acquire?
            lock(rl.cond_wait)
            try
                notify(rl.cond_wait)
            finally
                unlock(rl.cond_wait)
            end
        end
        GC.enable_finalizers()
    end
    return
end

function unlockall(rl::ReentrantLock)
    ct = current_task()
    n = rl.reentrancy_cnt
    @atomic :monotonic rl.reentrancy_cnt = 1
    unlock(rl)
    return n
end

function relockall(rl::ReentrantLock, n::Int)
    ct = current_task()
    lock(rl)
    n1 = rl.reentrancy_cnt
    @atomic :monotonic rl.reentrancy_cnt = n
    n1 == 1 || concurrency_violation()
    return
end

"""
    lock(f::Function, lock)

Acquire the `lock`, execute `f` with the `lock` held, and release the `lock` when `f`
returns. If the lock is already locked by a different task/thread, wait for it to become
available.

When this function returns, the `lock` has been released, so the caller should
not attempt to `unlock` it.

!!! compat "Julia 1.7"
    Using a [`Channel`](@ref) as the second argument requires Julia 1.7 or later.
"""
function lock(f, l::AbstractLock)
    lock(l)
    try
        return f()
    finally
        unlock(l)
    end
end

function trylock(f, l::AbstractLock)
    if trylock(l)
        try
            return f()
        finally
            unlock(l)
        end
    end
    return false
end

"""
    @lock l expr

Macro version of `lock(f, l::AbstractLock)` but with `expr` instead of `f` function.
Expands to:
```julia
lock(l)
try
    expr
finally
    unlock(l)
end
```
This is similar to using [`lock`](@ref) with a `do` block, but avoids creating a closure
and thus can improve the performance.
"""
macro lock(l, expr)
    quote
        temp = $(esc(l))
        lock(temp)
        try
            $(esc(expr))
        finally
            unlock(temp)
        end
    end
end

"""
    @lock_nofail l expr

Equivalent to `@lock l expr` for cases in which we can guarantee that the function
will not throw any error. In this case, avoiding try-catch can improve the performance.
See [`@lock`](@ref).
"""
macro lock_nofail(l, expr)
    quote
        temp = $(esc(l))
        lock(temp)
        val = $(esc(expr))
        unlock(temp)
        val
    end
end

@eval Threads begin
    """
        Threads.Condition([lock])

    A thread-safe version of [`Base.Condition`](@ref).

    To call [`wait`](@ref) or [`notify`](@ref) on a `Threads.Condition`, you must first call
    [`lock`](@ref) on it. When `wait` is called, the lock is atomically released during
    blocking, and will be reacquired before `wait` returns. Therefore idiomatic use
    of a `Threads.Condition` `c` looks like the following:

    ```
    lock(c)
    try
        while !thing_we_are_waiting_for
            wait(c)
        end
    finally
        unlock(c)
    end
    ```

    !!! compat "Julia 1.2"
        This functionality requires at least Julia 1.2.
    """
    const Condition = Base.GenericCondition{Base.ReentrantLock}

    """
    Special note for [`Threads.Condition`](@ref):

    The caller must be holding the [`lock`](@ref) that owns a `Threads.Condition` before calling this method.
    The calling task will be blocked until some other task wakes it,
    usually by calling [`notify`](@ref) on the same `Threads.Condition` object.
    The lock will be atomically released when blocking (even if it was locked recursively),
    and will be reacquired before returning.
    """
    wait(c::Condition)
end

"""
    Semaphore(sem_size)

Create a counting semaphore that allows at most `sem_size`
acquires to be in use at any time.
Each acquire must be matched with a release.
"""
mutable struct Semaphore
    sem_size::Int
    curr_cnt::Int
    cond_wait::Threads.Condition
    Semaphore(sem_size) = sem_size > 0 ? new(sem_size, 0, Threads.Condition()) : throw(ArgumentError("Semaphore size must be > 0"))
end

"""
    acquire(s::Semaphore)

Wait for one of the `sem_size` permits to be available,
blocking until one can be acquired.
"""
function acquire(s::Semaphore)
    lock(s.cond_wait)
    try
        while s.curr_cnt >= s.sem_size
            wait(s.cond_wait)
        end
        s.curr_cnt = s.curr_cnt + 1
    finally
        unlock(s.cond_wait)
    end
    return
end

"""
    release(s::Semaphore)

Return one permit to the pool,
possibly allowing another task to acquire it
and resume execution.
"""
function release(s::Semaphore)
    lock(s.cond_wait)
    try
        s.curr_cnt > 0 || error("release count must match acquire count")
        s.curr_cnt -= 1
        notify(s.cond_wait; all=false)
    finally
        unlock(s.cond_wait)
    end
    return
end


"""
    Event()

Create a level-triggered event source. Tasks that call [`wait`](@ref) on an
`Event` are suspended and queued until `notify` is called on the `Event`.
After `notify` is called, the `Event` remains in a signaled state and
tasks will no longer block when waiting for it.

!!! compat "Julia 1.1"
    This functionality requires at least Julia 1.1.
"""
mutable struct Event
    notify::Threads.Condition
    set::Bool
    Event() = new(Threads.Condition(), false)
end

function wait(e::Event)
    e.set && return
    lock(e.notify)
    try
        while !e.set
            wait(e.notify)
        end
    finally
        unlock(e.notify)
    end
    nothing
end

function notify(e::Event)
    lock(e.notify)
    try
        if !e.set
            e.set = true
            notify(e.notify)
        end
    finally
        unlock(e.notify)
    end
    nothing
end

@eval Threads begin
    import .Base: Event
    export Event
end
