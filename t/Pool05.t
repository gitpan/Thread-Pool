BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use Test::More tests => 11;
use strict;

diag( "Test job submission from different threads" );

my $pool;

BEGIN { use_ok('Thread::Pool') }

my $check;
my @list : shared;
my $count : shared = 0;
my $threads = 5;
my $times = 1000;

sub do { $_[0] }

sub stream { push( @list,$_[0] ) }

sub submit {
  while (1) {
    {
     lock( $count );
     return if $count == $times;
     $pool->job( ++$count );
    }
  }
}

$pool = Thread::Pool->new(
 {
  workers => $threads,
  do => \&do,
  stream => \&stream
 }
);
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( scalar($pool->workers),'==',$threads,'check initial number of workers');

my @thread;
push( @thread,threads->new( \&submit ) ) foreach 1..$threads;
$_->join foreach @thread;
cmp_ok( $count,'==',$times,		'check count' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers' );
cmp_ok( scalar($pool->removed),'==',$threads, 'check number of removed' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo' );
cmp_ok( $pool->done,'==',$times,	'check # jobs done' );

cmp_ok( scalar(@list),'==',$times,	'check length of list' );
$check .= $_ foreach 1..$times;
is( join('',@list),$check,		'check result' );
