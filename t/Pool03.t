BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use strict;
use IO::Handle; # needed, cause autoflush method doesn't load it
our $tests;
BEGIN {$tests = 1 + (2*5*17)}
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

my @amount = (
 [10,0],
 [5,5],
 [10,1000],
 [1,10000],
 [int(2+rand(8)),int(1+rand(10000))],
);


sub pre {
  return unless Thread::Queue::Any::Monitored->self;
  open( $handle,">$_[0]" ) or die "Could not open file $_[0]: $!";
}

sub post {
  return unless Thread::Queue::Any::Monitored->self;
  close( $handle );
}

sub do { sprintf( $format,$_[0] ) }

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

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #1' );
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
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #2' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #2' );
cmp_ok( scalar($pool->removed),'==',$t+$t+$t, 'check number of removed, #2' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #2' );
cmp_ok( $pool->done,'==',$times+$times,	'check # jobs done, #2' );

$notused = $pool->notused;
ok( $notused >= 0 and $notused < $t+$t+$t, 'check not-used threads, #2' );

open( $in,"<$file" ) or die "Could not read $file: $!";
is( join('',<$in>),$check,		'check second result' );
close( $in );

} #_runtest

} #SKIP:
