package Thread::Pool;

# Set the version information
# Make sure we do everything by the book from now on

$VERSION = '0.02';
use strict;

# Make sure we can do threads
# Make sure we can share here
# Make sure we can super duper queues
# Make sure we can freeze and thaw (just to make sure)

use threads ();
use threads::shared qw(share cond_wait cond_broadcast);
use Thread::Queue::Any ();
use Storable ();

# Satisfy -require-

1;

#---------------------------------------------------------------------------
#  IN: 1 class with which to create
#      2 reference to hash with parameters
#      3..N parameters to be passed to <pre> routine
# OUT: 1 instantiated object

sub new {

# Obtain the class
# Obtain the hash with parameters and bless it
# Die now if there is no subroutine to execute

    my $class = shift;
    my $self = bless shift,$class;
    die "Must have a subroutine to perform jobs" unless exists $self->{'do'};

# Create a super duper queue for it
# Set the auto-shutdown flag unless it is specified already
# Make sure all subroutines are code references
# Save the number of workers that were specified now (changed later)

    $self->{'queue'} = Thread::Queue::Any->new;
    $self->{'autoshutdown'} = 1 unless exists $self->{'autoshutdown'};
    $self->_makecoderef( caller().'::',qw(pre do post) );
    my $add = $self->{'workers'};

# Initialize the workers hash as shared
# Initialize the removed hash as shared
# Initialize the jobid counter as shared
# Initialize the result hash as shared
# Make sure references exist in the object

    my %workers : shared;
    my %removed : shared;
    my $jobid : shared = 1;
    my %result : shared;
    @$self{qw(workers removed jobid result)} =
     (\%workers,\%removed,\$jobid,\%result);

# Save a frozen value to the parameters for later hiring
# Add the number of workers indicated
# Return the instantiated object

    $self->{'startup'} = Storable::freeze( \@_ );
    $self->add( $add );
    return $self;
} #new

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2..N parameters to be passed for this job
# OUT: 1 jobid

sub job { 

# Obtain the object
# If we're interested in the returned result of this job
#  Obtain a jobid to be used
#  Have one of the threads handle this request with saving the result
#  Return the jobid of this job
# Have one of the threads handle this request without saving the result

    my $self = shift;
    if (defined( wantarray )) {
        my $jobid = $self->_jobid;
        $self->{'queue'}->enqueue( $jobid, \@_ );
        return $jobid;
    }
    $self->{'queue'}->enqueue( \@_ );
} #job

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1 number of jobs to be done still

sub todo { shift->{'queue'}->pending } #todo

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2..N tids of worker (default: all workers)
# OUT: 1 number of jobs done

sub done {

# Obtain the object
# Obtain references to the hashes with done values, keyed by tid
# Set to do all tids if none specified

    my $self = shift;
    my ($workers,$removed) = @$self{qw(workers removed)};
    @_ = (keys %{$workers},keys %{$removed}) unless @_;

# Initialize the number of jobs done
# Loop through all current worker tids and add the number of jobs
# Loop through all removed worker tids and add the number of jobs
# Return the result

    my $done = 0;
    $done += ($workers->{$_} || 0) foreach (@_);
    $done += ($removed->{$_} || 0) foreach (@_);
    return $done;
} #done

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 jobid for which to obtain result
# OUT: 1..N parameters returned from the job

sub result {

# Obtain the object
# Obtain the jobid
# Obtain local copy of result hash
# Make sure we have a value outside the block

    my $self = shift;
    my $jobid = shift;
    my $result = $self->{'result'};
    my $value;

# Lock the result hash
# Wait until the result is stored
# Obtain the frozen value
# Remove it from the result hash

    {
     lock( $result );
     cond_wait( $result ) until exists $result->{$jobid};
     $value = $result->{$jobid};
     delete( $result->{$jobid} );
    }

# Return the result of thawing

    @{Storable::thaw( $value )};
} #result

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 jobid for which to obtain result
# OUT: 1..N parameters returned from the job

sub result_dontwait {

# Obtain the object
# Obtain the jobid
# Obtain local copy of the result hash ref
# Make sure we have a value outside the block

    my $self = shift;
    my $jobid = shift;
    my $result = $self->{'result'};
    my $value;

# Lock the result hash
# Return now if there is no result
# Obtain the frozen value
# Remove it from the result hash

    {
     lock( $result );
     return unless exists $result->{$jobid};
     $value = $result->{$jobid};
     delete( $result->{$jobid} );
    }

# Return the result of thawing

    @{Storable::thaw( $value )};
} #result_dontwait

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 number of workers to have (default: no change)
# OUT: 1..N thread ids of final workforce

sub workers {

# Obtain the object
# Obtain the number of workers
# Obtain local copy of workers list

    my $self = shift;
    my $workers = $self->{'workers'};

# If a new number of workers specified
#  Make sure we're the only one adding or removing
#  Obtain current number of workers
#  If not enough workers
#   Add workers
#  Elseif too many workers
#   Remove workers

    if (@_) {
        lock( $workers );
        my $new = shift;
        my $current = keys %{$workers};
        if ($current < $new) {
            $self->add( $new - $current );
        } elsif( $current > $new ) {
            $self->remove( $current - $new );
        }
    }

# Return the number of workers now

    keys %{$workers};
} #workers

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 number of workers to add (default: 1)
# OUT: 1..N thread ids (optional)

sub add {

# Obtain the object
# Obtain the number of workers to add
# Obtain local copy of worker tids
# Initialize the list with tid's

    my $self = shift;
    my $add = shift || 1;
    my $workers = $self->{'workers'};
    my @tid;

# Make sure we're the only one hiring now
# For all of the workers we want to add
#  Start the thread with the starup parameters
#  Obtain the tid of the thread
#  Save the tid in the list
#  Initialize the number of jobs done by this worker

    lock( $workers );
    foreach (1..$add) {
        my $thread = threads->new(
         \&_dispatcher,
         $self,
         @{Storable::thaw( $self->{'startup'} )}
        );
	my $tid = $thread->tid;
        push( @tid,$tid );
        $workers->{$tid} = 0;
    }

# Return the thread id(s) of the worker threads created

    return wantarray ? @tid : $tid[0];
} #add

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 number of workers to remove
# OUT: 1..N jobid (optional)

sub remove {

# Obtain the object
# Obtain the number of workers to remove
# Initialize the list with jobid's

    my $self = shift;
    my $remove = shift || 1;
    my @jobid;

# If we want a jobid to be returned (we're interested in the <post> result)
#  For all of the workers we want to remove
#   Obtain a jobid to be used
#   Indicate we want to stop and keep the result
#   Add the jobid to the list

    if (defined( wantarray )) {
        foreach (1..$remove) {
            my $jobid = $self->_jobid;
            $self->{'queue'}->enqueue( 0,$jobid );
            push( @jobid,$jobid );
        }

# Else (we're not interested in results)
#  Just indicate we're want to stop as many as specified (without result saving)

    } else {
        $self->{'queue'}->enqueue( 0 ) foreach 1..$remove;
    }

# Return either the first or all of the jobids created

    return wantarray ? @jobid : $jobid[0];
} #remove

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1 1..N tid values of worker threads that were removed

sub removed { keys %{$_[0]->{'removed'}} } #removed

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1..N values returned by <pre>

sub pre { wantarray ? @{shift->{'pre'}} : shift->{'pre'}->[0] } #pre

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 new setting of autoshutdown flag
# OUT: 1 current/new setting of autoshutdown

sub autoshutdown {

# Obtain the object
# Set new setting if so specified
# Return the current/new setting

  my $self = shift;
  $self->{'autoshutdown'} = shift if @_;
  $self->{'autoshutdown'};
} #autoshutdown

#---------------------------------------------------------------------------
#  IN: 1 instantiated object

sub shutdown {

# Obtain the object
# Obtain local copy of the workers list reference

    my $self = shift;
    my $workers = $self->{'workers'};

# If there are still workers available
#  Remove all the workers
#  Lock the has with worker tids
#  Wait until all workers removed
#  Wait until all worker threads have actually finished

    if (my @worker = keys %{$workers}) {
        $self->remove( scalar(@worker) );
	lock( $workers );
        cond_wait( $workers ) while keys %{$workers};

#  For all of the workers
#   Obtain the thread object of this worker
#   Wait for it to end if there is still an object available

        foreach (@worker) {
            my $thread = threads->object( $_ );
            $thread->join if $thread;
        }
    }
} #shutdown

#---------------------------------------------------------------------------

# Internal subroutines

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 namespace to be prefixed
#      3..N fields to change to code refs (if available)

sub _makecoderef {

# Obtain the object
# Obtain the namespace to add to non fully qualified names

    my $self = shift;
    my $namespace = shift;

# For all of the fields specified
#  Reloop if doesn't exist
#  Reloop if already a reference
#  Prefix namespace if not fully qualified
#  Change name to code reference

    foreach (@_) {
        next unless exists $self->{$_};
        next if ref($self->{$_});
        $self->{$_} = $namespace.$self->{$_} unless $self->{$_} =~ m#::#;
        $self->{$_} = \&{$self->{$_}};
    }
} #_makecoderef

#---------------------------------------------------------------------------
#  IN: 1 hash reference
#      2..N parameters to be passed to <pre>

sub _dispatcher {

# Obtain the object
# Reset auto-shutdown flag in copy of object in this thread
# Save the tid of the thread we're in
# Save a reference to the workers pool for faster access

    my $self = shift;
    $self->{'autoshutdown'} = 0; # only ONE may shutdown in DESTROY!
    my $tid = threads->tid;
    my $workers = $self->{'workers'};

# Perform the pre actions, save a reference to the result in the local object

    $self->{'pre'} = [exists $self->{'pre'} ? $self->{'pre'}->($self,@_) : ()];

# Create a local copy of the queue object
# Initialize the list of parameters returned (we need it outside later)
# While we're handling requests
#  Fetch the next job when it becomes available
#  Outloop if we're supposed to die

    my $queue = $self->{'queue'};
    my @list;
    while (1) {
        @list = $queue->dequeue;
	last unless $list[0];

#  If no one is interested in the result
#   Execute the job without saving the result
#  Else (someone is interested, so first parameter is jobid)
#   Execute the job and save the frozen result
#  Increment number of jobs done by this worker

        if (ref($list[0])) {
            $self->{'do'}->( $self,@{$list[0]} );
        } else {
            $self->_freeze( $list[0], $self->{'do'}->( $self, @{$list[1]} ) );
        }
        $workers->{$tid}++;
    }

# If someone is interested in the result of <end> (so we have a jobid)
#  Execute the post-action (if there is one) and save the frozen result
# Else (nobody's interested)
#  Execute the post-action if there is one

    if ($list[1]) {
	$self->_freeze(
	 $list[1],
	 exists $self->{'post'} ? $self->{'post'}->( $self,@_ ) : ()
	);
    } else {
        $self->{'post'}->( $self,@_ ) if exists $self->{'post'};
    }

# Make sure we're the only one working on the workers list
# Mark this worker thread as removed
# Forget this worker thread as available
# Notify everybody else about changes here

    lock( $workers );
    $self->{'removed'}->{$tid} = $workers->{$tid};
    delete( $workers->{$tid} );
    cond_broadcast( $workers );
} #_dispatcher

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1 jobid

sub _jobid {

# Obtain the object
# Obtain a local copy of the jobid counter
# Lock the jobid counter
# Return the current value, incrementing it on the fly

    my $self = shift;
    my $jobid = $self->{'jobid'};
    lock( $jobid );
    ${$jobid}++;
} #_jobid

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 jobid
#      3..N values to store

sub _freeze {

# Obtain the object
# Obtain the jobid
# Obtain local copy of the result hash

    my $self = shift;
    my $jobid = shift;
    my $result = $self->{'result'};

# Make sure we have only access to the result hash
# Store the already frozen result
# Make sure other threads get woken up

    lock( $result );
    $result->{$jobid} = Storable::freeze( \@_ );
    cond_broadcast( $result );
} #_freeze

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 jobid
# OUT: 1..N result from indicated job

sub _thaw {

# Obtain the object
# Obtain the jobid
# Obtain local copy of result hash
# Make sure we have a value outside of the block

    my $self = shift;
    my $jobid = shift;
    my $result = $self->{'result'};
    my $value;

# Make sure we're the only ones in the result hash
# Obtain the frozen value
# Remove it from the result hash

    {
     lock( $result );
     $value = $result->{$jobid};
     delete( $result->{$jobid} );
    }

# Return the result of thawing

    @{Storable::thaw( $value )};
} #_thaw

#---------------------------------------------------------------------------

# Standard Perl functionality methods

#---------------------------------------------------------------------------
#  IN: 1 instantiated object

sub DESTROY {

# Obtain the object
# Shutdown if so required

    my $self = shift;
    $self->shutdown if $self->{'autoshutdown'};
} #DESTROY

#---------------------------------------------------------------------------

__END__

=head1 NAME

Thread::Pool - group of threads for performing similar jobs

=head1 SYNOPSIS

 use Thread::Pool;
 $pool = Thread::Pool->new(
  {
   autoshutdown => 1, # default: 1 = yes
   workers => 5,      # default: 1
   pre => sub {shift; print "starting worker with @_\n",
   do => sub {shift; print "doing job for @_\n"; reverse @_},
   post => sub {shift; print "stopping worker with @_\n",
  },
  qw(a b c)           # parameters to pre-job subroutine
 );

 $pool->job( qw(d e f) );              # not interested in result

 $jobid = $pool->job( qw(g h i) );
 @result = $pool->result( $jobid );    # wait for result to be ready
 print "Result is @result\n";

 $jobid = $pool->job( qw(j k l) );
 @result = $pool->result_dontwait( $jobid ); # do _not_ wait for result
 print "Result is @result\n";          # may be empty when not ready yet

 $pool->add;           # add worker(s)
 $pool->remove;        # remove worker(s)
 $pool->workers( 10 ); # set number of workers

 $workers = $pool->workers; 
 $removed = $pool->removed;
 print "$workers workers available, $removed workers removed\n";
    
 $todo = $pool->todo;
 $done = $pool->done;
 print "$done jobs done, still $todo jobs todo\n";

 $pool->autoshutdown( 1 ); # shutdown when object is destroyed
 $pool->shutdown;          # wait until all jobs done

 @pre = shift->pre; # inside do() and post() only;

=head1 DESCRIPTION

The Thread::Pool allows you to set up a group of (worker) threads to execute
a (large) number of similar jobs that need to be executed asynchronously.  The
routine that actually performs the job (the "do" routine), must be specified
as a reference to a (anonymous) subroutine.

Once a pool is created, L<job>s can be executed at will and will be assigned
to the next available worker.  If the result of the job is important, a
job ID is issued.  The job ID can then later be used to obtain the L<result>.

Initialization parameters can be passed during the creation of the
threads::farm object.  The initialization ("pre") routine can be specified
as a reference to a (anonymous) subroutine.  Parameters returned from the
initialization routine are available to the "do" and "post" routine.  The
"pre" routine can e.g. be used to create a connection to an external source
using a non-threadsafe library.

When a worker is told to finish, the "post" routine is executed if available.

Unless told otherwise, all jobs that are assigned, will be executed before
the pool is allowed to be destroyed.

=head1 METHODS

=head2 new

 $pool = Thread::Pool->new(
  {
   do => sub {shift; print "doing with @_\n"; reverse @_}, # must have
   pre => sub {shift; print "starting with @_\n",      # default: none
   post => sub {shift; print "stopping with @_\n",     # default: none
   workers => 5,      # default: 1
   autoshutdown => 1, # default: 1 = yes
  },
  qw(a b c)           # parameters to "pre" subroutine
 );

The "new" method returns the Thread::Pool object.

The first input parameter is a reference to a hash that should at least
contain the "do" key with a subroutine reference.

The other input parameters are optional.  If specified, they are passed to the
the "pre" subroutine whenever a new worker is L<add>ed.

Each time a worker thread is added, the "pre" subroutine (if available) will
be called inside the thread.  Its return values are saved and made available
to the "do" and "post" routines by means of the L<pre> method.  Each time a
worker thread is L<remove>d, the "post" routine is called.  Its return value(s)
are saved only if a job ID was requested when removing the thread.  Then the
L<result> method can be called to obtain the results of the "post" subroutine.

The following field B<must> be specified in the hash reference:

=over 2

=item do

 do => 'do_the_job',		# assume caller's namespace

or:

 do => 'Package::do_the_job',

or:

 do => \&SomeOther::do_the_job,

or:

 do => sub {print "anonymous sub doing the job\n"},

The "do" field specifies the subroutine to be executed for each L<job>.  It
must be specified as either the name of a subroutine or as a reference to a
(anonymous) subroutine.

The specified subroutine should expect the following parameters to be passed:

 1     the Thread::Pool object to which the worker thread belongs.
 2..N  any parameters that were passed with the call to L<job>.

Any values that are returned by this subroutine after finishing each job, are
accessible with L<result> if a job ID was requested when assigning the L<job>.

The L<pre> method can be called on the Thread::Pool object to gain access to
the values returned by the "pre" subroutine.

=back

The following fields are B<optional> in the hash reference:

=over 2

=item pre

 pre => 'prepare_jobs',		# assume caller's namespace

or:

 pre => 'Package::prepare_jobs',

or:

 pre => \&SomeOther::prepare_jobs,

or:

 pre => sub {print "anonymous sub preparing the jobs\n"},

The "pre" field specifies the subroutine to be executed B<each> time a new
worker thread is B<started> (either when starting the pool, or when new worker
threads are added with a call to either L<add> or L<workers>).  It must be
specified as either the name of a subroutine or as a reference to a
(anonymous) subroutine.

The specified subroutine should expect the following parameters to be passed:

 1     the Thread::Pool object to which the worker thread belongs.
 2..N  any additional parameters that were passed with the call to L<new>.

Any values that are returned by this subroutine after initializing the thread,
accessible with the L<pre> method inside the "do" and "post" subroutines.

=item post

 post => 'cleanup_after_worker',	# assume caller's namespace

or:

 post => 'Package::cleanup_after_worker',

or:

 post => \&SomeOther::cleanup_after_worker,

or:

 post => sub {print "anonymous sub cleaning up after the worker removed\n"},

The "post" field specifies the subroutine to be executed B<each> time a worker
thread is B<removed> (either when being specifically L<remove>d, or when the
pool is L<shutdown> specifically or implicitely when the Thread::Pool object
is destroyed.  It must be specified as either the name of a subroutine or as
a reference to a (anonymous) subroutine.

The specified subroutine should expect the following parameters to be passed:

 1     the Thread::Pool object to which the worker thread belongs.
 2..N  any additional parameters that were passed with the call to L<new>.

Any values that are returned by this subroutine after closing down the thread,
are accessible with the L<result> method, but only if the thread was
L<removed> and a job ID was requested.

=item workers

 workers => 5, # default: 1

The "workers" field specifies the number of worker threads that should be
created when the pool is created.  If no "workers" field is specified, then
only one worker thread will be created.  The L<workers> method can be used
to change the number of workers later. 

=item autoshutdown

 autoshutdown => 0, # default: 1

The "autoshutdown" field specified whether the L<shutdown> method should be
called when the object is destroyed.  By default, this flag is set to 1
indicating that the shutdown method should be called when the object is
being destroyed.  Setting the flag to a false value, will cause the shutdown
method B<not> to be called, causing potential loss of data and error messages
when threads are not finished when the program exits.

The setting of the flag can be later changed by calling the L<autoshutdown>
method.

=back

=head2 job

 $jobid = $pool->job( @parameter );	# saves result
 $pool->job( @parameter );		# does not save result

The "job" method specifies a job to be executed by any of the available
L<workers>.  Which worker will execute the job, is indeterminate.

The input parameters are passed to the "do" subroutine as is.

If a return value is requested, then the return value(s) of the "do"
subroutine will be saved.  The returned value is a job ID that should be
used as the input parameter to L<result> or L<result_dontwait>.

=head2 result

 @result = $pool->result( $jobid );

The "result" method waits for the specified job to be finished and returns
the result of that job.

The input parameter is the job id as returned from the L<job> assignment.

The return value(s) are what was returned by the "do" routine.  The meaning
of the return value(s) is entirely up to you as the developer.

If you don't want to wait for the job to be finished, but just want to see
if there is a result already, use the L<result_dontwait> method.

=head2 result_dontwait

 @result = $pool->result_dontwait( $jobid );

The "result_dontwait" method returns the result of the job if it is available.
If the job is not finished yet, it will return undef in scalar context or the
empty list in list context.

The input parameter is the job id as returned from the L<job> assignment.

If the result of the job is available, then the return value(s) are what was
returned by the "do" routine.  The meaning of the return value(s) is entirely
up to you as the developer.

If you want to wait for the job to be finished, use the L<result> method.

=head2 todo

 $todo = $pool->todo;

The "todo" method returns the number of L<job>s that are still left to be
done.

=head2 done

 $done = $pool->done;

The "done" method returns the number of L<job>s that has been performed by
current and L<removed> worker threads of the pool.

=head2 add

 $tid = $pool->add;		# add 1 worker thread
 @tid = $pool->add( 5 );

The "add" method adds the specified number of worker threads to the pool
and returns the thread ID's (tid) of the threads that were created.

The input parameter specifies the number of workers to be added.  If no
number of workers is specified, then 1 worker thread will be added.

In scalar context, returns the thread ID (tid) of the first worker thread
that was added.  This usually only makes sense if you're adding only one
worker thread.

In list context, returns the thread ID's (tid) of the worker threads that
were created.

Each time a worker thread is added, the "pre" subroutine (if available) will
be called inside the thread.  Its return values are saved and made available
to the "do" and "post" routines by means of the L<pre> method.

=head2 remove

 $pool->remove;			# remove 1 worker thread
 $pool->remove( 5 );		# remove 5 worker threads

 $jobid = $pool->remove;	# remove 1 worker thread, save result
 @jobid = $pool->remove( 5 );	# remove 5 worker threads, save results

The "remove" method adds the specified number of special "remove" job to the
lists of jobs to be done.  It will return the job ID's if called in a non-void
context.

The input parameter specifies the number of workers to be removed.  If no
number of workers is specified, then 1 worker thread will be removed.

In void context, the results of the execution of the "post" subroutine(s)
is discarded.

In scalar context, returns the job ID of the result of the first worker
thread that was removed.  This usually only makes sense if you're removing
only one worker thread.

In list context, returns the job ID's of the result of all the worker
threads that were removed.

Each time a worker thread is L<remove>d, the "post" routine is called.  Its
return value(s) are saved only if a job ID was requested when removing the
thread.  Then the L<result> method can be called to obtain the results of
the "post" subroutine.

=head2 workers

 $workers = $pool->workers;	# find out number of worker threads
 $pool->workers( 10 );		# set number of worker threads

The "workers" method can be used to find out how many worker threads there
are currently available, or it can be used to set the number of worker
threads.

The input value, if specified, specifies the number of worker threads that
should be available.  If there are more worker threads available than the
number specified, then superfluous worker threads will be L<remove>d.  If
there are not enough worker threads available, new worker threads will be
L<add>ed.

The return value is the current number of worker threads.

=head2 removed

 $removed = $pool->removed;

The "removed" method returns the number of worker threads that were
L<remove>d over the lifetime of the object.

=head2 autoshutdown

 $pool->autoshutdown( 1 );
 $autoshutdown = $pool->autoshutdown;

The "autoshutdown" method sets and/or returns the flag indicating whether an
automatic L<shutdown> should be performed when the object is destroyed.

=head2 shutdown

 $pool->shutdown;

The "shutdown" method waits for all L<job>s to be executed, then L<remove>s
all worker threads and then returns.  It is called automatically when the
object is destroyed, unless specifically disabled by providing a false value
with the "autoshutdown" field when creating the pool with L<new>, or by
calling the L<autoshutdown> method.

=head2 pre

 my $self = shift;	# obtain the pool object
 my @pre = $self->pre;	# obtain result of "pre" subroutine
 			# rest of parameters now in @_

The "pre" method only makes sense within the "do" and "post" subroutine that
is specified when the pool is created with L<new>.  It returns whatever was
returned by the "pre" subroutine of pool, as specified when creating the
thread with L<new>.

This allows you to pass values and structures that should live for the
lifetime of the worker thread in which it is called.

=head1 CAVEATS

Passing unshared values between threads is accomplished by serializing the
specified values using C<Storable>.  This allows for great flexibility at
the expense of more CPU usage.  It also limits what can be passed, as e.g.
code references can B<not> be serialized and therefor not be passed.

=head1 AUTHOR

Elizabeth Mattijsen, <liz@dijkmat.nl>.

Please report bugs to <perlbugs@dijkmat.nl>.

=head1 COPYRIGHT

Copyright (c) 2002 Elizabeth Mattijsen <liz@dijkmat.nl>. All rights
reserved.  This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<threads>, L<Thread::Queue::Any>, L<Storable>.

=cut
