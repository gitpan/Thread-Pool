BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use strict;
use IO::Handle; # needed, cause autoflush method doesn't load it
our $tests;
BEGIN {$tests = 1 + (2*2*17)}
use Test::More tests => $tests;

BEGIN { use_ok('Thread::Pool') }

SKIP: {

eval {require Thread::Queue::Any::Monitored};
skip( "Thread::Queue::Any::Monitored not installed", $tests-1 ) if $@;

my $check;
my $format = '%5d';
my @list;

my $file = 'anymonitor';
my $handle;

# [1,10000],
# [10,1000],
# [int(1+rand(9)),int(1+rand(10000))],
my @amount = (
 [10,0],
 [5,5],
);


sub pre {
  return unless Thread::Queue::Any::Monitored->self;
  open( $handle,">$_[0]" ) or die "Could not open file $_[0]: $!";
  $handle->autoflush( 1 ); # must flush otherwise other threads don't see
}

sub do { sprintf( $format,$_[0] ) }

sub yield { threads::yield(); sprintf( $format,$_[0] ) }

sub file { print $handle $_[0] }


_runtest( @{$_},qw(pre do file) ) foreach @amount;
_runtest( @{$_},qw(pre yield file) ) foreach @amount;


unlink( $file );


sub _runtest {

my ($t,$times,$pre,$do,$monitor) = @_;
diag( "Now testing $t thread(s) for $times jobs" );

$check = '';

my $pool = Thread::Pool->new(
 {
  workers => $t,
  pre => $pre,
  do => $do,
  monitor => $monitor,
 },
 $file
);
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( scalar($pool->workers),'==',$t,	'check initial number of workers' );

foreach ( 1..$times ) {
  $pool->job( $_ );
  $check .= sprintf( $format,$_ );
}

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',1,'check for remaining threads, #1' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #1' );
cmp_ok( scalar($pool->removed),'==',$t, 'check number of removed, #1' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #1' );
cmp_ok( $pool->done,'==',$times,	'check # jobs done, #1' );

my $notused = $pool->notused;
ok( $notused >= 0 and $notused <= $t,	'check not-used threads, #1' );

open( my $in,"<$file" ) or die "Could not read $file: $!";
is( join('',<$in>),$check,		'check first result' );
close( $in );

diag( "Now testing ".($t+$t)." thread(s) for $times jobs" );
$pool->job( $_ ) foreach 1..$times;

$pool->workers( $t+$t);
cmp_ok( scalar($pool->workers),'==',$t+$t, 'check number of workers, #2' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',1,'check for remaining threads, #2' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #2' );
cmp_ok( scalar($pool->removed),'==',$t+$t+$t, 'check number of removed, #2' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #2' );
cmp_ok( $pool->done,'==',$times+$times,	'check # jobs done, #2' );

$notused = $pool->notused;
ok( $notused >= 0 and $notused < $t+$t+$t, 'check not-used threads, #2' );

open( $in,"<$file" ) or die "Could not read $file: $!";
is( join('',<$in>),$check.$check,	'check second result' );
close( $in );

} #_runtest

} #SKIP:
