BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use Test::More tests => 22;
use strict;

diag( "Test abort() functionality" );

BEGIN { use_ok('Thread::Pool') }

my $check = '';
my @list : shared = ('');
my $threads = 10;
my $times = 100;

sub do { sleep( rand(2) ); $_[0] }

sub stream { push( @list,$_[0] ) }

my $pool = Thread::Pool->new( {workers => 10,do => \&do, stream => \&stream} );
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( scalar($pool->workers),'==',$threads,'check initial number of workers');

$pool->job( $_ ) foreach 1..$times;
$pool->abort;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #1' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #1' );
cmp_ok( scalar($pool->removed),'==',$threads, 'check number of removed, #1' );

my $todo = $pool->todo;
my $done = $pool->done;
ok( $todo >= 0 and $todo <= $times,	'check # jobs todo, #1' );
ok( $done >= 0 and $done <= $times,	'check # jobs done, #1' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #2' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #2' );
cmp_ok( scalar($pool->removed),'==',$threads, 'check number of removed, #2' );

$pool->add( 5 );
cmp_ok( scalar(()=threads->list),'==',5,'check for remaining threads, #3' );
cmp_ok( scalar($pool->workers),'==',5,	'check number of workers, #3' );
cmp_ok( scalar($pool->removed),'==',$threads, 'check number of removed, #3' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0,'check for remaining threads, #4' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #4' );
cmp_ok( scalar($pool->removed),'==',$threads+5, 'check number of removed, #4' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #2' );
cmp_ok( $pool->done,'==',$times,	'check # jobs done, #2' );

my $notused = $pool->notused;
ok( $notused >= 0 and $notused <= $threads, 'check not-used threads, #1' );
cmp_ok( $#list,'==',$times,		'check length of list, #1' );

$check .= $_ foreach 1..$times;
is( join('',@list),$check,		'check result' );
