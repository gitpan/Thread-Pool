BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use strict;
use IO::Handle; # needed, cause autoflush method doesn't load it
use Test::More tests => 2 + (2*2*3*23);

diag( "Test monitoring to file" );

BEGIN { use_ok('Thread::Pool') }

my $check;
my $format = '%5d';
my @list;

my $file = 'anymonitor';
my $handle;

# [1,1000],
# [int(2+rand(8)),int(1+rand(1000))],
my @amount = (
 [10,0],
 [5,5],
 [10,100],
);


sub pre {
  return if Thread::Pool->self;
  ok( open( $handle,">$_[0]" ),		'open monitoring file' );
}

sub post {
  return unless Thread::Pool->monitor;
  ok( close( $handle ),			'close monitoring file' );
}

sub do { sprintf( $format,$_[0] ) }

sub yield { threads::yield(); sprintf( $format,$_[0] ) }

sub file { print $handle $_[0] }

foreach my $optimize (qw(cpu memory)) {
  diag( qq(*** Test using fast "do" optimize for $optimize ***) );
  _runtest( $optimize,@{$_},qw(pre do file post) ) foreach @amount;

  diag( qq(*** Test using slower "yield" optimize for $optimize ***) );
  _runtest( $optimize,@{$_},qw(pre yield file post) ) foreach @amount;
}

ok( unlink( $file ),			'check unlinking of file' );


sub _runtest {

my ($optimize,$t,$times,$pre,$do,$monitor,$post) = @_;
diag( "Now testing $t thread(s) for $times jobs" );

my $pool = pool( $optimize,$t,$pre,$do,$monitor,$post,$file );
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
$pool = pool( $optimize,$t,$pre,$do,$monitor,$post,$file );
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( scalar($pool->workers),'==',$t,	'check initial number of workers' );

$pool->job( $_ ) foreach 1..$times;

$pool->workers( $t+$t);
cmp_ok( scalar($pool->workers),'==',$t+$t, 'check number of workers, #2' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #2' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #2' );
cmp_ok( scalar($pool->removed),'==',$t+$t, 'check number of removed, #2' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #2' );
cmp_ok( $pool->done,'==',$times,	'check # jobs done, #2' );

$notused = $pool->notused;
ok( $notused >= 0 and $notused < $t+$t,	'check not-used threads, #2' );

open( $in,"<$file" ) or die "Could not read $file: $!";
is( join('',<$in>),$check,		'check second result' );
close( $in );

} #_runtest


sub pool { Thread::Pool->new(
 {
  optimize => shift,
  workers => shift,
  pre => shift,
  do => shift,
  monitor => shift,
  post => shift,
  maxjobs => undef,
 },
 shift
);
} #pool