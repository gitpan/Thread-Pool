BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use strict;
use Test::More tests => 39;

diag( "Test general functionality" );

BEGIN { use_ok('Thread::Pool') }

my $pool = Thread::Pool->new(
 {
  pre		=> 'pre',
  do		=> 'main::do',
  post		=> \&post,
 },
 qw(a b c)
);
isa_ok( $pool,'Thread::Pool',		'check object type' );

can_ok( $pool,qw(
 abort
 add
 autoshutdown
 new
 notused
 done
 dont_set_result
 job
 jobid
 join
 remove
 remove_me
 removed
 result
 result_dontwait
 self
 set_result
 shutdown
 todo
 waitfor
 workers
) );

cmp_ok( scalar($pool->workers),'==',1,	'check number of workers' );
$pool->job( qw(d e f) );	# do a job, for statistics only

my $todo = $pool->todo;
ok( $todo >= 0 and $todo <= 1,		'check # jobs todo, #1' );
cmp_ok( scalar($pool->workers),'==',1,	'check number of workers, #1' );

my $jobid1 = $pool->job( qw(g h i) );
cmp_ok( $jobid1,'==',1,			'check first jobid' );

my $jobid2 = $pool->job( qw(k l m) );
cmp_ok( $jobid2,'==',2,			'check second jobid' );

cmp_ok( $pool->add,'==',2,		'check tid of 2nd worker thread' );
cmp_ok( scalar($pool->workers),'==',2,	'check number of workers, #2' );

$pool->workers( 10 );
cmp_ok( scalar($pool->workers),'==',10,	'check number of workers, #3' );

$pool->workers( 5 );
cmp_ok( scalar($pool->workers),'==',5,	'check number of workers, #4' );
cmp_ok( scalar($pool->removed),'==',5,	'check number of removed, #1' );

$todo = $pool->todo;
ok( $todo >= 0 and $todo <= 3,		'check # jobs todo, #2' );

my @result = $pool->result_dontwait( $jobid1 );
ok( !@result or (join('',@result) eq 'ihg'), 'check result_dontwait' );

@result = $pool->result( $jobid2 );
is( join('',@result),'mlk',		'check result' );

my $jobid3 = $pool->remove;
cmp_ok( $jobid3,'==',3,			'check third jobid' );

@result = $pool->result( $jobid3 );
is( join('',@result),'abcabc',		'check result remove' );

cmp_ok( scalar($pool->workers),'==',4,	'check number of workers, #5' );
cmp_ok( scalar($pool->removed),'==',6,	'check number of removed, #2' );

$pool->shutdown;
foreach (threads->list) {
  warn "Thread #".$_->tid." still alive\n";
}
cmp_ok( scalar(()=threads->list),'==',0, 'check for remaining threads' );

cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #6' );
cmp_ok( scalar($pool->removed),'==',10,	'check number of removed, #3' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #3' );
cmp_ok( $pool->done,'==',3,		'check # jobs done, #3' );

my $notused = $pool->notused;
ok( $notused >= 0 and $notused < 10,	'check not-used threads, #1' );

my $jobid4 = $pool->job( 1,2,3 );
cmp_ok( $jobid4,'==',4,			'check fourth jobid' );

my $tid = $pool->add;
cmp_ok( $tid,'==',11,			'check tid, #2' );
my @worker = $pool->workers;
my @thread = map {$_->tid} threads->list;
cmp_ok( scalar($pool->workers),'==',1,	'check number of workers, #7' );

@result = $pool->result( $jobid4 );
is( join('',@result),'321',		'check result after add' );

@result = $pool->waitfor( qw(m n o) );
is( join('',@result),'onm',		'check result waitfor' );

my $jobid5 = $pool->job( 'remove_me' );
cmp_ok( $jobid5,'==',6,			'check fifth jobid' );

my ($result) = $pool->result( $jobid5 );
is( $result,'remove_me',		'check result remove_me' );

cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #4' );
cmp_ok( $pool->done,'==',6,		'check # jobs done, #4' );
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #7' );
cmp_ok( scalar($pool->removed),'==',11,	'check number of removed, #4' );

$pool->shutdown;
cmp_ok( scalar(()=threads->list),'==',0, 'check for remaining threads' );

$notused = $pool->notused;
ok( $notused >= 0 and $notused < 11,	'check not-used threads, #2' );

sub pre { reverse @_ }

sub do {
  Thread::Pool->self->remove_me if $_[0] eq 'remove_me';
  reverse @_;
}

sub post { (@_,@_) }
