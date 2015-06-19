(** A way to limit the number of concurrent computations.

    A throttle is essentially a pipe to which one can feed jobs.

    A throttle schedules asynchronous jobs so that at any point in time no more than
    [max_concurrent_jobs] jobs are running.  A job [f] is considered to be running from
    the time [f ()] is executed until the deferred returned by [f ()] becomes determined,
    or [f ()] raises.  The throttle initiates jobs first-come first-served.

    One can use [create_with] to create a throttle with "resources" that one would
    like to make available to concurrent jobs and to guarantee that different jobs
    access different resources.

    A throttle is killed if one of its jobs throws an exception, and the throttle has
    [continue_on_error = false].  A throttle can also be explicitly [kill]ed.  If a
    throttle is killed, then all jobs in it that haven't yet started are aborted,
    i.e. they will not start and will become determined with [`Aborted].  Jobs that had
    already started will continue, and return [`Ok] or [`Raised] as usual when they
    finish.  Jobs enqueued into a killed throttle will be immediately aborted.
*)

open Core_kernel.Std

module Deferred = Deferred1

(** We use a phantom type to distinguish between throttles, which have
    [max_concurrent_jobs >= 1], and sequencers, which have [max_concurrent_jobs = 1].  All
    operations are available on both.  We make the distinction because it is sometimes
    useful to know from the type of a throttle that it is a sequencer and that at most one
    job can be running at a time. *)
module T2 : sig
  type ('a, 'kind) t with sexp_of
  include Invariant.S2 with type ('a, 'b) t := ('a, 'b) t
end

type 'a t = ('a, [`throttle]) T2.t with sexp_of

include Invariant.S1 with type 'a t := 'a t

(** [create ~continue_on_error ~max_concurrent_jobs] returns a throttle that will run up
    to [max_concurrent_jobs] concurrently.

    If some job raises an exception, then the throttle will be killed, unless
    [continue_on_error] is true. *)
val create
  :  continue_on_error:bool
  -> max_concurrent_jobs:int
  -> unit t

(** [create_with ~continue_on_error job_resources] returns a throttle that will run up to
    [List.length job_resources] concurrently, and will ensure that all running jobs are
    supplied distinct elements of [job_resources]. *)
val create_with
  :  continue_on_error:bool
  -> 'a list
  -> 'a t

type 'a outcome = [ `Ok of 'a | `Aborted | `Raised of exn ] with sexp_of

(** [enqueue t job] schedules [job] to be run as soon as possible.  Jobs are guaranteed to
    be started in the order they are [enqueue]d and to not be started during the call to
    [enqueue].  If [t] is dead, then [job] will be immediately aborted (for [enqueue] this
    will send an exception to the monitor in effect). *)
val enqueue' : ('a, _) T2.t -> ('a -> 'b Deferred.t) -> 'b outcome Deferred.t
val enqueue  : ('a, _) T2.t -> ('a -> 'b Deferred.t) -> 'b         Deferred.t

(** [monad_sequence_how ~how ~f] returns a function that behaves like [f], except that it
    uses a throttle to limit the number of concurrent invocations can be running
    simultaneously.  The throttle has [continue_on_error = false]. *)
val monad_sequence_how
  :  ?how : Monad_sequence.how
  -> f    : ('a -> 'b Deferred.t)
  -> ('a -> 'b Deferred.t) Staged.t

val monad_sequence_how2
  :  ?how : Monad_sequence.how
  -> f    : ('a1 -> 'a2 -> 'b Deferred.t)
  -> ('a1 -> 'a2 -> 'b Deferred.t) Staged.t

(** [prior_jobs_done t] becomes determined when all of the jobs that were previously
    enqueued in [t] have completed. *)
val prior_jobs_done : (_, _) T2.t -> unit Deferred.t

(** [max_concurrent_jobs t] returns the maximum number of jobs that [t] will run
    concurrently. *)
val max_concurrent_jobs : (_, _) T2.t -> int

(** [num_jobs_running t] returns the number of jobs that [t] is currently running.  It
    is guaranteed that if [num_jobs_running t < max_concurrent_jobs t] then
    [num_jobs_waiting_to_start t = 0].  That is, the throttle always uses its maximum
    concurrency if possible. *)
val num_jobs_running : (_, _) T2.t -> int

(** [num_jobs_waiting_to_start t] returns the number of jobs that have been [enqueue]d but
    have not yet started. *)
val num_jobs_waiting_to_start : (_ , _) T2.t -> int

(** [capacity_available t] becomes determined the next time that [t] has fewer than
    [max_concurrent_jobs t] running, and hence an [enqueue]d job would start
    immediately. *)
val capacity_available : (_, _) T2.t -> unit Deferred.t

(** [kill t] kills [t], which aborts all enqueued jobs that haven't started and all jobs
    enqueued in the future.  [kill] also initiates the [at_kill] clean functions.

    If [t] has already been killed, then calling [kill t] has no effect. *)
val kill : _ t -> unit

(** [is_dead t] returns [true] if [t] was killed, either by [kill] or by an unhandled
    exception in a job. *)
val is_dead : _ t -> bool

(** [at_kill t clean] runs [clean] on each resource when [t] is killed, either by [kill]
    or an unhandled exception.  [clean] is called on each resource as it becomes
    available, i.e. immediately if the resource isn't currently in use, otherwise when the
    job currently using the resource finishes.  If a call to [clean] fails, the exception
    is raised to the monitor in effect when [at_kill] was called. *)
val at_kill : 'a t -> ('a -> unit Deferred.t) -> unit

(** [cleaned t] becomes determined after [t] is killed and all of its [at_kill] clean
    functions have completed. *)
val cleaned : _ t -> unit Deferred.t

(** A sequencer is a throttle that is specialized to only allow one job at a time and to,
    by default, not continue on error. *)
module Sequencer : sig
  type 'a t = ('a, [`sequencer]) T2.t with sexp_of

  val create : ?continue_on_error:bool (** default is [false] *) -> 'a -> 'a t
end