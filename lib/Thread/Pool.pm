package Thread::Pool;

# Set the version information
# Make sure we do everything by the book from now on

$VERSION = '0.16';
use strict;

# Make sure we can do threads
# Make sure we can share here
# Make sure we can super duper queues
# Make sure we can freeze and thaw (just to make sure)

use threads ();
use threads::shared ();
use Thread::Queue::Any ();
use Storable ();

# Number of times this namespace has been CLONEd
# Allow for self referencing within job thread
# Flag to indicate whether the current thread should be removed
# The current jobid, when available
# Flag to indicate result should _not_ be saved (assume another thread will)

my $cloned = 0;
my $SELF;
my $remove_me;
my $jobid;
my $dont_set_result;

# Satisfy -require-

1;

#---------------------------------------------------------------------------
#  IN: 1 class with which to create
#      2 reference to hash with parameters
#      3..N parameters to be passed to "pre" routine
# OUT: 1 instantiated object

sub new {

# Obtain the class
# Obtain the hash with parameters and bless it
# Save the clone level
# Die now if there is no subroutine to execute

    my $class = shift;
    my $self = bless shift,$class;
    $self->{'cloned'} = $cloned;
    die "Must have a subroutine to perform jobs" unless exists $self->{'do'};

# If we're supposed to monitor
#  Load the appropriate module if not already available
#  Die now if also attempting to stream

    if (exists $self->{'monitor'}) {
        eval {require Thread::Queue::Any::Monitored}
         unless defined( $Thread::Queue::Any::Monitored::VERSION );
        die "Cannot stream and monitor at the same time"
         if exists $self->{ 'stream'};

#  Make sure we have a real coderef for the pre and the monitoring routine
#  Create a monitoring thread
#  Set the streaming routine that sends to the monitor

        $self->_makecoderef( caller().'::',qw(pre monitor post) );
        @$self{qw(monitorq monitort)} = Thread::Queue::Any::Monitored->new(
         {
          pre => $self->{'pre'},
          monitor => $self->{'monitor'},
          post => $self->{'post'},
	  exit => $self->{'exit'},
         },
	 @_
        );
        $self->{'stream'} = \&_have_monitored;
    }

# Create a super duper queue for it
# Set the auto-shutdown flag unless it is specified already
# Set the dispatcher to be used if none specified yet
# Save the originating thread id (workers can only be added/removed there)

    $self->{'jobq'} = Thread::Queue::Any->new;
    $self->{'autoshutdown'} = 1 unless exists $self->{'autoshutdown'};
    $self->{'dispatcher'} ||= $self->{'stream'} ? \&_stream : \&_random;
    $self->{'originatingtid'} = threads->tid;

# Make sure all subroutines are code references
# Save the number of workers that were specified now (changed later)

    $self->_makecoderef( caller().'::',qw(pre do post stream dispatcher) );
    my $add = $self->{'workers'};

# Initialize the workers threads list as shared
# Initialize the removed hash as shared
# Initialize the jobid counter as shared
# Initialize the result hash as shared
# Initialize the streamid counter as shared
# Initialize the running flag
# Initialize the destroyed flag

    my @workers : shared;
    my %removed : shared;
    my $jobid : shared = 1;
    my %result : shared;
    my $streamid : shared = 1;
    my $running : shared = 1;
    my $destroyed : shared = 0;

# Make sure references exist in the object

    @$self{qw(workers removed jobid result streamid running destroyed)} =
     (\@workers,\%removed,\$jobid,\%result,\$streamid,\$running,\$destroyed);

# Save a frozen value to the parameters for later hiring
# Make sure there is an originating id to check against
# Add the number of workers indicated
# Return the instantiated object

    $self->{'startup'} = Storable::freeze( \@_ );
    $self->{'originatingid'} = threads->tid;
    $self->add( $add );
    return $self;
} #new

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2..N parameters to be passed for this job
# OUT: 1 jobid

sub job { 

# Obtain the object
# If we're streaming
#  Die now if an individual jobid requested
#  Enqueue with a jobid obtained on the fly

    my $self = shift;
    if ($self->{'stream'}) {
        die "Cannot return individual results when streaming"
         if defined( wantarray );
        $self->{'jobq'}->enqueue( $self->_jobid, \@_ );

# Elseif we want a jobid
#  Obtain a jobid
#  Enqueue with that jobid
#  And return with that jobid now

    } elsif (defined( wantarray )) {
        my $jobid = $self->_jobid;
        $self->{'jobq'}->enqueue( $jobid, \@_ );
        return $jobid;

# Else (not streaming and not interested in the result)
#  Enqueue without a jobid

    } else {
        $self->{'jobq'}->enqueue( \@_ )
    }
} #job

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2..N parameters to be passed for this job
# OUT: 1..N parameters returned from the job

sub waitfor {

# Obtain the object
# Submit the job, obtain the jobid and wait for the result

    my $self = shift;
    $self->result( $self->job( @_ ) );
} #waitfor

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1 number of jobs to be done still

sub todo { shift->{'jobq'}->pending } #todo

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2..N tids of removed worker (default: all removed workers)
# OUT: 1 number of jobs done

sub done {

# Obtain the object
# Obtain references to the hashes with done values, keyed by tid
# Set to do all tids if none specified

    my $self = shift;
    my $removed = $self->{'removed'};
    @_ = keys %{$removed} unless @_;

# Initialize the number of jobs done
# Loop through all removed worker tids and add the number of jobs
# Return the result

    my $done = 0;
    $done += ($removed->{$_} || 0) foreach @_;
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
     threads::shared::cond_wait( $result ) until exists $result->{$jobid};
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
    my ($workers,$removed) = @$self{qw(workers removed)};

# If a new number of workers specified
#  Die now if we're trying to set number or workers in wrong thread

    if (@_) {
        $self->_check_originating_thread( 'workers' );

#  Make sure we're the only one adding or removing
#  Obtain current number of workers
#  If not enough workers
#   Add workers
#  Elseif too many workers
#   Remove workers

        lock( $workers );
        my $new = shift;
        my $current = $self->workers;
        if ($current < $new) {
            $self->add( $new - $current );
        } elsif( $current > $new ) {
            $self->remove( $current - $new );
        }
    }

# Return now if in void context
# Loop through all workers and return only those not in removed

    return unless defined(wantarray);
    map {exists( $removed->{$_} ) ? () : ($_)} @{$workers};
} #workers

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 number of workers to add (default: 1)
# OUT: 1..N thread ids (optional)

sub add {

# Obtain the object
# Die now if not in the correct thread

    my $self = shift;
    $self->_check_originating_thread( 'add' );

# Obtain the number of workers to add
# Die now if not a proper number of workers to add
# Obtain local copy of worker tids and dispatcher
# Initialize the list with tid's

    my $add = shift || 1;
    die "Must add at least one thread" unless $add > 0;
    my ($workers,$dispatcher) = @$self{qw(workers dispatcher)};
    my @tid;

# Thaw the original input parameters to
# If there is a monitor queue but no thread
#  Recreate the monitoring thread using the current monitoring queue

    @_ = @{Storable::thaw( $self->{'startup'} )};
    if ($self->{'monitorq'} and not exists( $self->{'monitort'} ) ) {
        @$self{qw(monitorq monitort)} = Thread::Queue::Any::Monitored->new(
         {
          pre => $self->{'pre'},
          monitor => $self->{'monitor'},
          queue => $self->{'monitorq'},
          post => $self->{'post'},
	  exit => $self->{'exit'},
         },
	 @_,
        );
    }

# Make sure we're the only one adding now
# For all of the workers we want to add
#  Start the thread with the startup parameters
#  Obtain the tid of the thread
#  Save the tid in the local list
#  Save the tid in the global list

    lock( $workers );
    foreach (1..$add) {
        my $thread = threads->new( $dispatcher,$self,@_ );
	my $tid = $thread->tid;
        push( @tid,$tid );
        push( @{$workers},$tid );
    }

# Reset shut down flag if we added any worker threads
# Return the thread id(s) of the worker threads created

    $self->{'shutdown'} = 0;
    return wantarray ? @tid : $tid[0];
} #add

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 number of workers to remove
# OUT: 1..N jobid (optional)

sub remove {

# Obtain the object
# Die now if not in the correct thread

    my $self = shift;
    $self->_check_originating_thread( 'remove' );

# Obtain the number of workers to remove
# Die now if improper number of workers to remove
# Initialize the list with jobid's

    my $remove = shift || 1;
    die "Must remove at least one thread" unless $remove > 0;
    my @jobid;

# If we want a jobid to be returned (we're interested in the <post> result)
#  For all of the workers we want to remove
#   Obtain a jobid to be used
#   Indicate we want to stop and keep the result
#   Add the jobid to the list

    if (defined( wantarray )) {
        foreach (1..$remove) {
            my $jobid = $self->_jobid;
            $self->{'jobq'}->enqueue( 0,$jobid );
            push( @jobid,$jobid );
        }

# Else (we're not interested in results)
#  Just indicate we're want to stop as many as specified (without result saving)

    } else {
        $self->{'jobq'}->enqueue( 0 ) foreach 1..$remove;
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
#      2..N thread ID's to join (default: all active threads marked removed)

sub join {

# Obtain the object
# Die now if not in the right thread
# Obtain local copies of removed hash and workers list

    my $self = shift;
    $self->_check_originating_thread( 'join' );
    my ($removed,$workers) = @$self{qw(removed workers)};

# Make sure we're the only ones doing the workers list
# Obtain local copy of the worker's tids
# Set default list to join if no threads specified yet

    lock( $workers );
    my @worker = @{$workers};
    @_ = map {exists( $removed->{$_} ) ? ($_) : ()} @worker unless @_;

# For all of the threads to be joined
#  If there is a thread for this tid still
#   Join that thread
#  Else
#   Die, thread seems to have vanished without saying goodbye

    foreach (@_) {
        if (my $thread = threads->object( $_ )) {
            $thread->join;
        } else {
            die "Thread #$_ seems to have gone without notification";
        }
    }

# Set the new list of worker threads

    @{$workers} = map {exists( $removed->{$_} ) ? () : ($_)} @worker;
} #join

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
# Die now if not in the correct thread
# Return now if are already shut down
# Mark the object as shut down now (in case we die in here)

    my $self = shift;
    $self->_check_originating_thread( 'shutdown' );
    return if $self->{'shutdown'};
    $self->{'shutdown'} = 1;

# Notify all available active workers after all jobs
# Join all workers, active or non-active (should be all now)

    $self->workers( 0 );
    $self->join( @{$self->{'workers'}} );

# If we were streaming
#  Obtain the current stream ID, job ID and result hash
#  Set the extra parameters to be passed to streamer if monitoring
#  Make sure we're the only one handling results
#  Obtain last ID to loop through

    if (my $stream = $self->{'stream'}) {
        my ($streamid,$jobid,$result) = @$self{qw(streamid jobid result)};
        my @extra = exists $self->{'monitorq'} ? ($self) : ();
	lock( $result );
        my $last = $self->_first_todo_jobid;

#  For all the results that still need to be streamd
#   Die if there is no result (_should_ be there by now)
#   Call the "stream" routine with this result
#   Delete the result from the hash
#  Set the stream ID for any further streaming later

        for (my $i = $$streamid; $i < $last; $i++) {
            die "Cannot find result for streaming job $i"
             unless exists( $result->{$i} );
            $stream->( @extra,@{Storable::thaw( $result->{$i} )} );
            delete( $result->{$i} );
        }
        $$streamid = $last;
    }

# If there is a monitoring thread
#  Tell the monitoring to stop
#  Remove the thread information from the object
#  Wait for the thread to finish

    if (my $thread = $self->{'monitort'}) {
        $self->{'monitorq'}->enqueue( undef );
	delete( $self->{'monitort'} );
        $thread->join;
    }
} #shutdown

#---------------------------------------------------------------------------
#  IN: 1 instantiated object

sub abort {

# Obtain the object
# Die now if in the wrong thread

    my $self = shift;
    $self->_check_originating_thread( 'abort' );

# Reset the flag that we're running
# While there are still workers active
#  Reset to 0 workers if there are no jobs left to do (they won't see the flag)
#  Give the other threads a chance
# Set the running flag again (in case workers get added later)
# Collect the actual threads

    ${$self->{'running'}} = 0;
    while ($self->workers) {
        $self->workers( 0 ) unless $self->todo;
        threads::yield();
    }
    ${$self->{'running'}} = 1;
    $self->join;
} #abort

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
# OUT: 1 number of threads that have not done any jobs

sub notused {

# Obtain the object
# Obtain local copy of removed workers hash
# Initialize counter

    my $self = shift;
    my $removed = $self->{'removed'};
    my $notused = 0;

# Make sure we're the only ones doing this
# Loop for all worker threads that were removed
#  Increment counter if no jobs were done by this thread
# Return the resulting amount

    lock( $removed );
    foreach (keys %{$removed}) {
        $notused++ unless $removed->{$_};
    }
    return $notused;
} #notused

#---------------------------------------------------------------------------
#  IN: 1 class (ignored)
# OUT: 1 instantiated queue object

sub self { $SELF } #self

#---------------------------------------------------------------------------
#  IN: 1 instantiated object or class (ignored)

sub remove_me { $remove_me = 1 } #remove_me

#---------------------------------------------------------------------------
#  IN: 1 instantiated object or class (ignored)
# OUT: 1 jobid of the job currently handled by this thread

sub jobid { $jobid } #jobid

#---------------------------------------------------------------------------
#  IN: 1 instantiated object or class (ignored)

sub dont_set_result { $dont_set_result = 1 } #dont_set_result

#---------------------------------------------------------------------------
#  IN: 1 instantiated object
#      2 jobid
#      3..N values to store

sub set_result {

# Obtain the object
# Obtain the jobid
# Return now if we're not supposed to save and it's its own job

    my $self = shift;
    my $set_jobid = shift;
    return if $dont_set_result and $set_jobid == $jobid;

# Obtain local copy of the result hash
# Make sure we have only access to the result hash
# Store the already frozen result
# Make sure other threads get woken up

    my $result = $self->{'result'};
    lock( $result );
    $result->{$set_jobid} = Storable::freeze( \@_ );
    threads::shared::cond_broadcast( $result );
} #set_result

#---------------------------------------------------------------------------

# Basic dispatcher routines

#---------------------------------------------------------------------------
#  IN: 1 hash reference
#      2..N parameters to be passed to "pre" routine

sub _random {

# Obtain the object and save it for later self-reference
# Reset auto-shutdown flag in copy of object in this thread
# Save the tid of the thread we're in
# Initialize the number of jobs

    my $self = $SELF = shift;
    $self->{'autoshutdown'} = 0; # only ONE may shutdown in DESTROY!
    my $tid = threads->tid;
    my $jobs = 0;

# Obtain local copies from the hash for faster access
# Perform the pre actions if there are any

    my ($jobq,$do,$post,$result,$removed,$workers,$running) =
     @$self{qw(jobq do post result removed workers running)};
    $self->{'pre'}->( @_ ) if exists $self->{'pre'};

# Initialize the list of parameters returned (we need it outside later)
# While we're handling requests
#  Fetch the next job when it becomes available
#  Outloop if we're supposed to die
#  Reset the don't save flag

    my (@list,$running_now);
    while ($running_now = $$running) {
        @list = $jobq->dequeue;
	last unless $list[0];
        $dont_set_result = undef;

#  If no one is interested in the result
#   Reset the jobid
#   Execute the job without saving the result
#  Else (someone is interested, so first parameter is jobid)
#   Set the jobid
#   Execute the job and save the frozen result
#  Increment number of jobs done by this worker

        if (ref($list[0])) {
	    $jobid = undef;
            $do->( @{$list[0]} );
        } else {
	    $jobid = $list[0];
            $self->set_result( $jobid, $do->( @{$list[1]} ) );
        }
        $jobs++;

#  Reloop if we're supposed to continue with this thread
#  Reset the jobid, we don't want the result to be saved ever
#  Start shutting down this worker thread

        next unless $remove_me;
        $list[1] = '';
        last;
    }

# If we're not aborting
#  Reset the don't save flag
#  If someone is interested in the result of "remove" (so we have a jobid)
#   Execute the post-action (if there is one) and save the frozen result
#  Else (nobody's interested)
#   Execute the post-action if there is one
# Mark this worker thread as removed

    if ($running_now) {
        $dont_set_result = undef;
        if ($jobid = $list[1]) {
            $self->set_result( $list[1], $post ? $post->( @_ ) : () );
        } else {
            $post->( @_ ) if $post;
        }
    }
    { lock( $removed ); $self->{'removed'}->{$tid} = $jobs; }
} #_random

#---------------------------------------------------------------------------
#  IN: 1 hash reference
#      2..N parameters to be passed to "pre" routine

sub _stream {

# Obtain the object and save for self reference
# Reset auto-shutdown flag in copy of object in this thread
# Save the tid of the thread we're in
# Initialize the number of jobs

    my $self = $SELF = shift;
    $self->{'autoshutdown'} = 0; # only ONE may shutdown in DESTROY!
    my $tid = threads->tid;
    my $jobs = 0;

# Obtain local copies from the hash for faster access
# Perform the pre actions if there are any
# Set the extra parameters to be passed to streamer if monitoring

    my ($jobq,$do,$post,$result,$stream,$streamid,$removed,$workers,$running) =
     @$self{qw(jobq do post result stream streamid removed workers running)};
    $self->{'pre'}->( @_ ) if exists $self->{'pre'};
    my @extra = exists $self->{'monitorq'} ? ($self) : ();

# Initialize the stuff that we need outside later
# While we're handling requests, keeping copy of the flag on the fly
#  Fetch the next job when it becomes available
#  Outloop if we're supposed to die
#  Reset the don't save flag

    my (@list,$running_now);
    while ($running_now = $$running) {
        @list = $jobq->dequeue;
	last unless $jobid = $list[0];
        $dont_set_result = undef;

#  If we're in sync (this job is the next one to be streamed)
#   Obtain the result of the job
#   If we're supposed to save the result
#    Stream the result of the job immediately
#    Increment stream id
#   Increment number of jobs
#   And reloop

        if ($$streamid == $jobid) {
            my @param = $do->( @{$list[1]} );
            unless ($dont_set_result) {
                $stream->( @extra,@param );
                { lock($streamid); ${$streamid} = $jobid+1 }
            }
            $jobs++;
	    next;
        }

#  Execute the job and save the result
#  Increment number of jobs done by this worker

        my @param = $do->( @{$list[1]} );
        $jobs++;

#  Make sure we are the only one doing this
#  Obtain the current stream ID (so we can use it later)
#  For all of the results from the stream ID to this thread's job ID
#   Outloop if there is no result yet
#   Call the "stream" routine with the result

        {
         lock( $streamid );
         my $i = $$streamid;
         for (; $i < $jobid; $i++) {
             last unless exists( $result->{$i} );
	     {
	      lock( $result );
              $stream->( @extra,@{Storable::thaw( $result->{$i} )} );
              delete( $result->{$i} );
             }
         }

#  If all results until this job ID have been streamed
#   If we need to save this result
#    Call the "stream" routine with the result of this job
#    Set the stream ID to handle the result after this one
#  Else (not all results where available)
#   Freeze the result of this job for later handling
#   Set the stream ID to the job ID for which there was no result yet

         if ($i == $jobid) {
             unless ($dont_set_result) {
                 $stream->( @extra,@param );
                 $$streamid = $jobid+1;
             }
         } else {
             $self->set_result( $jobid, @param );
             $$streamid = $i;
         }
        }

#  Reloop if we're supposed to continue with this thread
#  Reset the jobid, we don't want the result to be saved ever
#  Start shutting down this worker thread

        next unless $remove_me;
        $list[1] = '';
        last;
    }

# If we're not aborting
#  Reset the don't save flag
#  If someone is interested in the result of <end> (so we have a jobid)
#   Execute the post-action (if there is one) and save the frozen result
#  Else (nobody's interested)
#   Execute the post-action if there is one
# Mark this worker thread as removed

    if ($running_now) {
        $dont_set_result = undef;
        if ($list[1]) {
            $self->set_result( $list[1], $post ? $post->( @_ ) : () );
        } else {
            $post->( @_ ) if $post;
        }
    }
    { lock( $removed ); $self->{'removed'}->{$tid} = $jobs; }
} #_stream

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
#  IN: 1 instantiated object
#      2 name of subroutine that is not allowed to be called

sub _check_originating_thread {

# Die now if in the wrong thread

    die qq(Can only call "$_[1]" in the originating thread)
#     unless threads->tid == $_[0]->{'originatingid'};
     unless $_[0]->{'cloned'} == $cloned;
} #_check_originating_thread

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
#  IN: 1 instantiated Thread::Pool object
# OUT: 1 job id of first todo job

sub _first_todo_jobid {

# Obtain the object
# Obtain the reference to the job queue
# Make sure we're the only one handling the job queue

    my $self = shift;
    my $jobq = $self->{'jobq'};
    lock( $jobq );

# For all the jobs in the queue
#  De-frost the values in there
#  Return the job id if it is a job with a job id
# Return the next job id that is going to be issued

    foreach (@{$jobq}) {
        my @param = @{Storable::thaw( $_ )};
	return $param[0] if @param == 2;
    }
    return ${$self->{'jobid'}};
} #_first_todo_jobid

#---------------------------------------------------------------------------
#  IN: 1 instantiate Thread::Pool object
#      2..N any parameters returned as a result of a job

sub _have_monitored {

# Obtain the object
# Enqueue the parameters with at least an empty string to prevent premature exit

    my $self = shift;
    $self->{'monitorq'}->enqueue( @_ ? @_ : ('') );
} #_have_monitored

#---------------------------------------------------------------------------

# Standard Perl functionality methods

#---------------------------------------------------------------------------
#  IN: 1 namespace being cloned (ignored)

sub CLONE { $cloned++ } #CLONE

#---------------------------------------------------------------------------
#  IN: 1 instantiated object

sub DESTROY {

# Obtain the object
# Return now if we're in a rogue DESTROY
# Return now if we're not allowed to run DESTROY
# Do the shutdown if shutdown is required

    my $self = shift;
    return if !defined( $self ) or not exists $self->{'cloned'}; # HACK
    return unless $self->{'cloned'} == $cloned;
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
   stream => sub {shift; print "streamline with @_\n",
   monitor => sub { print "monitor with @_\n",
  },
  qw(a b c)           # parameters to "pre" subroutine
 );

 $pool->job( qw(d e f) );              # not interested in result

 $jobid = $pool->job( qw(g h i) );
 @result = $pool->result( $jobid );    # wait for result to be ready
 print "Result is @result\n";

 $jobid = $pool->job( qw(j k l) );
 @result = $pool->result_dontwait( $jobid ); # do _not_ wait for result
 print "Result is @result\n";          # may be empty when not ready yet

 @result = $pool->waitfor( qw(m n o) ); # submit and wait for result
 print "Result is @result\n";

 $pool->add;           # add worker(s)
 $pool->remove;        # remove worker(s)
 $pool->workers( 10 ); # set number of workers
 $pool->join;          # wait for all removed worker threads to finish

 $workers = $pool->workers; 
 $todo    = $pool->todo;
 $removed = $pool->removed;
 print "$workers workers, $todo jobs todo, $removed workers removed\n";

 $pool->autoshutdown( 1 ); # shutdown when object is destroyed
 $pool->shutdown;          # wait until all jobs done
 $pool->abort;             # finish current job and remove all workers

 $done    = $pool->done;   # simple thread-use statistics
 $notused = $pool->notused;

 Thread::Pool->remove_me;  # inside "do" only

=head1 DESCRIPTION

                    *** A note of CAUTION ***

 This module only functions on Perl versions 5.8.0-RC3 and later.
 And then only when threads are enabled with -Dusethreads.  It is
 of no use with any version of Perl before 5.8.0-RC3 or without
 threads enabled.

                    *************************
The Thread::Pool allows you to set up a group of (worker) threads to execute
a (large) number of similar jobs that need to be executed asynchronously.  The
routine that actually performs the job (the "do" routine), must be specified
as a name or a reference to a (anonymous) subroutine.

Once a pool is created, L<job>s can be executed at will and will be assigned
to the next available worker.  If the result of the job is important, a
job ID is issued.  The job ID can then later be used to obtain the L<result>.

Initialization parameters can be passed during the creation of the
threads::farm object.  The initialization ("pre") routine can be specified
as a name or as a reference to a (anonymous) subroutine.  The "pre" routine
can e.g. be used to create a connection to an external source using a
non-threadsafe library.

When a worker is told to finish, the "post" routine is executed if available.

Results of jobs must be obtained seperately, unless a "stream" or a "monitor"
routine is specified.  Then the result of each job will be streamed to the
"stream" or "monitor" routine in the order in which the jobs were submitted.

Unless told otherwise, all jobs that are assigned, will be executed before
the pool is allowed to be destroyed.  If a "stream" or "monitor" routine
is specified, then all results will be handled by that routine before the
pool is allowed to be destroyed.

=head1 CLASS METHODS

The following class methods are available.

=head2 new

 $pool = Thread::Pool->new(
  {
   do => sub { print "doing with @_\n" },        # must have
   pre => sub { print "starting with @_\n",      # default: none
   post => sub { print "stopping with @_\n",     # default: none

   workers => 5,      # default: 1
   autoshutdown => 1, # default: 1 = yes

   stream => sub { print "streamline with @_\n", # default: none
   monitor => sub { print "monitor with @_\n",   # default: none
  },

  qw(a b c)           # parameters to "pre" routine

 );

The "new" method returns the Thread::Pool object.

The first input parameter is a reference to a hash that should at least
contain the "do" key with a subroutine reference.

The other input parameters are optional.  If specified, they are passed to the
the "pre" subroutine whenever a new worker is L<add>ed.

Each time a worker thread is added, the "pre" subroutine (if available) will
be called inside the thread.  Each time a worker thread is L<remove>d, the
"post" routine is called.  Its return value(s) are saved only if a job ID was
requested when removing the thread.  Then the L<result> method can be called
to obtain the results of the "post" subroutine.

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

 1..N  any parameters that were passed with the call to L<job>.

Any values that are returned by this subroutine after finishing each job, are
accessible with L<result> if a job ID was requested when assigning the L<job>.

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
threads are added with a call to either L<add> or L<workers>) and once when a
"monitor" routine is specified.  It must be specified as either the name of a
subroutine or as a reference to a (anonymous) subroutine.

The specified subroutine should expect the following parameters to be passed:

 1..N  any additional parameters that were passed with the call to L<new>.

You can determine whether the "pre" routine is called for a new worker thread
or for a monitoring thread by checking C<caller()> inside the "pre" routine.

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

 1..N  any additional parameters that were passed with the call to L<new>.

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

=item stream

 stream => 'in_order_of_submit',	# assume caller's namespace

or:

 stream => 'Package::in_order_of_submit',

or:

 stream => \&SomeOther::in_order_of_submit,

or:

 stream => sub {print "anonymous sub called in order of submit\n"},

The "stream" field specifies the subroutine to be executed for streaming the
results of the "do" routine.  If specified, the "stream" routine is called
once for the result of each "do" subroutine, but in the order in which the
L<job>s were submitted rather than in the order in which the result were
obtained (which is by the very nature of threads, indeterminate).

The specified subroutine should expect the following parameters to be passed:

 1     the Thread::Pool object to which the worker thread belongs.
 2..N  the values that were returned by the "do" subroutine

The "stream" routine is executed in B<any> of the threads that are created
for the Thread::Pool object.  The system attempts to call the "stream"
routine in the same thread from which the values are obtained, but when
things get out of sync, other threads may stream the result of a job.  If
you want B<only one> thread to stream all results, use the "monitor" routine.

=item monitor

 monitor => 'in_order_of_submit',	# assume caller's namespace

or:

 monitor => 'Package::in_order_of_submit',

or:

 monitor => \&SomeOther::in_order_of_submit,

or:

 monitor => sub {print "anonymous sub called in order of submit\n"},

The "monitor" field specifies the subroutine to be executed for monitoring the
results of the "do" routine.  If specified, the "monitor" routine is called
once for the result of each "do" subroutine, but in the order in which the
L<job>s were submitted rather than in the order in which the result were
obtained (which is by the very nature of threads, indeterminate).

The specified subroutine should expect the following parameters to be passed:

 1..N  the values that were returned by the "do" subroutine

To be able to use this function, the L<Thread::Queue::Any::Monitored> module
must also be available.  It will be loaded automatically if it has not been
C<use>d yet.

The "monitor" routine is executed in its own thread.  This means that all
results have to be passed between threads, and therefore be frozen and thawed
with L<Storable>.  If you can handle the streaming from different threads,
it is probably wiser to use the "stream" routine feature.

=back

=head1 POOL METHODS

The following methods can be executed on the Thread::Pool object.

=head2 job

 $jobid = $pool->job( @parameter );	# saves result
 $pool->job( @parameter );		# does not save result

The "job" method specifies a job to be executed by any of the available
L<workers>.  Which worker will execute the job, is indeterminate.  When it
will happen, depends on the number of jobs that still have to be done when
this job was submitted.

The input parameters are passed to the "do" subroutine as is.

If a return value is requested, then the return value(s) of the "do"
subroutine will be saved.  The returned value is a job ID that should be
used as the input parameter to L<result> or L<result_dontwait>.

=head2 waitfor

 @result = $pool->waitfor( @parameter ); # submit job and wait for result

The "waitfor" method specifies a job to be executed, wait for the result to
become ready and return the result.  It is in fact a shortcut for using
L<job> and L<result>.

The input parameters are passed to the "do" subroutine as is.

The return value(s) are what was returned by the "do" routine.  The meaning
of the return value(s) is entirely up to you as the developer.

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

Each time a worker thread is added, the "pre" routine (if available) will
be called inside the thread.

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

=head2 join

 $pool->join;

The "join" method waits until all of the worker threads that have been
L<remove>d have finished their jobs.  It basically cleans up the threads
that are not needed anymore.

The "shutdown" method call the "join" method after removing all the active
worker threads.  You therefore seldom need to call the "join" method
seperately.

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

The "shutdown" method waits for all L<job>s to be executed, L<remove>s
all worker threads, handles any results that still need to be streamed, before
it returns.  Call the L<abort> method if you do not want to wait until all
jobs have been executed.

It is called automatically when the object is destroyed, unless specifically
disabled by providing a false value with the "autoshutdown" field when
creating the pool with L<new>, or by calling the L<autoshutdown> method.

Please note that the "shutdown" method does not disable anything.  It just
shuts all of the worker threads down.  After a shutdown it B<is> possible
to add L<job>s, but they won't get done until workers are L<add>ed.

=head2 abort

The "abort" method waits for all worker threads to finish their B<current>
job, L<remove>s all worker threads, before it returns.  Call the L<shutdown>
method if you want to wait until all jobs have been done.

Please note that the "abort" method does not disable anything.  It just
shuts all of the worker threads down.  After an abort it B<is> possible
to add L<job>s, but they won't get done until workers are L<add>ed.

Also note that any streamed results are B<not> handled.  If you want to
handle any streamed results, you can call the L<shutdown> method B<after>
calling the "abort" method.

=head2 done

 $done = $pool->done;

The "done" method returns the number of L<job>s that has been performed by
the L<removed> worker threads of the pool.

The "done" method is typically called after the L<shutdown> method
has been called.

=head2 notused

 $notused = $pool->notused;

The "notused" method returns the number of removed threads that have not
performed any jobs.  It provides a heuristic to determine how many
L<workers> you actually need for a specific application: a value > 0
indicates that you have specified too many worker threads for this
application.

The "notused" method is typically called after the L<shutdown> method
has been called.

=head1 INSIDE JOB METHODS

The following methods only make sense inside the "pre", "do", "post",
"stream" and "monitor" routines.

=head2 self

 $pool = Thread::Pool->self;

The class method "self" returns the object to which this thread belongs.
It is available within the "pre", "do", "post", "stream" and "monitor"
subroutines only.

=head2 remove_me

 Thread::Pool->remove_me;

The "remove_me" class method only makes sense within the "do" subroutine.
It indicates to the job dispatcher that this worker thread should be removed
from the pool.  After the "do" subroutine returns, the worker thread will
be removed.

=head2 jobid

 Thread::Pool->jobid;

The "jobid" class method only makes sense within the "do" subroutine in
streaming mode.  It returns the job ID value of the current job.  This can
be used connection with the L<dont_set_result> and the L<set_result> methods
to have another thread set the result of the current job.

=head2 dont_set_result

 Thread::Pool->dont_set_result;

The "dont_set_result" class method only makes sense within the "do" subroutine.
It indicates to the job dispatcher that the result of this job should B<not>
be saved.  This is for cases where the result of this job will be placed in
the result hash at some time in the future by another thread using the
L<set_result> method.

=head2 set_result

 Thread::Pool->self->set_result( $jobid,@param );

The "set_result" object method only makes sense within the "do" subroutine.
It allows you to set the result of B<other> jobs than the one currently being
performed.

This method is only needed in B<very> special situations.  Normally, just
returning values from the "do" subroutine is enough to have the result saved.
This method is exposed to the outside world in those cases where a specific
thread becomes responsible for setting the result of other threads (which
used the L<dont_set_result> method to defer saving their result.

The first input parameter specifies the job ID of the job for which to set
the result.  The rest of the input parameters is considered to be the result
to be saved.  Whatever is specified in the rest of the input parameters, will
be returned with the L<result> or L<result_dontwait> methods.

=head1 CAVEATS

Passing unshared values between threads is accomplished by serializing the
specified values using C<Storable>.  This allows for great flexibility at
the expense of more CPU usage.  It also limits what can be passed, as e.g.
code references can B<not> be serialized and therefore not be passed.

=head1 BUGS

For some still unexplained reason, calling 

=head1 EXAMPLES

For now the only examples available, are those found in the "t" directory.

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
