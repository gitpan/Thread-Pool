BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use strict;
use IO::Handle;
our $tests;
BEGIN {$tests = 1 + (2*5*10)}
use Test::More tests => $tests;

diag( "Test job throttling" );

BEGIN { use_ok('Thread::Pool') }

SKIP: {

eval {require Thread::Queue::Any::Monitored};
skip( "Thread::Queue::Any::Monitored not installed", $tests-1 ) if $@;

my $check;
my $format = '%5d';
my @list;

my $file = 'anymonitor';
my $handle;

my @amount = (
 [10,0],
 [5,5],
 [10,100],
 [1,25],
 [int(5+rand(6)),int(301+rand(700))],
);


sub pre {
  return unless Thread::Pool->monitor;
  open( $handle,">$_[0]" ) or die "Could not open file $_[0]: $!";
  $handle->autoflush;
}

sub post {
  return unless Thread::Pool->monitor;
  close( $handle );
}

sub do { sleep( rand(2) ); sprintf( $format,$_[0] ) }

sub yield { threads::yield(); sprintf( $format,$_[0] ) }

sub file { print $handle $_[0] }

diag( qq(*** Test using fast "do" ***) );
_runtest( @{$_},qw(pre do file post) ) foreach @amount;

diag( qq(*** Test using slower "yield" ***) );
_runtest( @{$_},qw(pre yield file post) ) foreach @amount;


unlink( $file );


sub _runtest {

my ($t,$times,$pre,$do,$monitor,$post) = @_;
diag( "Now testing $t thread(s) for $times jobs" );

my $pool = Thread::Pool->new(
 {
  workers => $t,
  pre => $pre,
  do => $do,
  monitor => $monitor,
  post => $post,
 },
 $file
);
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( scalar($pool->workers),'==',$t,	'check initial number of workers' );

$check = '';
foreach ( 1..$times ) {
  $pool->job( $_ );
  $check .= sprintf( $format,$_ );
}

#warn "Waiting for jobs to finish\n";
#threads::yield() while $pool->results;

diag( "Now testing ".($t+$t)." thread(s) for $times jobs" );
$pool->job( $_ ) foreach 1..$times;

$pool->workers( $t+$t );
cmp_ok( scalar($pool->workers),'==',$t+$t, 'check number of workers' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers' );
cmp_ok( scalar($pool->removed),'==',$t+$t, 'check number of removed' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo' );
cmp_ok( $pool->done,'==',$times+$times,	'check # jobs done' );

my $notused = $pool->notused;
ok( $notused >= 0 and $notused < $t+$t,	'check not-used threads' );

open( my $in,"<$file" ) or die "Could not read $file: $!";
is( join('',<$in>),$check.$check,	'check second result' );
close( $in );

} #_runtest

} #SKIP:
