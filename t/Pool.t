BEGIN {				# Magic Perl CORE pragma
    if ($ENV{PERL_CORE}) {
        chdir 't' if -d 't';
        @INC = '../lib';
    }
}

use Test::More tests => 25;

BEGIN { use_ok('Thread::Pool') }

my $pool = Thread::Pool->new(
 {
  pre		=> \&pre,
  do		=> \&do,
  post		=> \&post,
 },
 qw(a b c)
);
isa_ok( $pool,'Thread::Pool',		'check object type' );
cmp_ok( $pool->workers,'==',1,		'check number of workers' );

$pool->job( qw(d e f) );	# do a job, for statistics only
my $todo = $pool->todo;
ok( $todo >= 0 and $todo <= 1,		'check # jobs todo, #1' );
my $done = $pool->done;
ok( $done >= 0 and $done <= 1,		'check # jobs done, #1' );
cmp_ok( $pool->workers,'==',1,		'check number of workers, #1' );

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
$done = $pool->done;
ok( $done >= 0 and $done <= 3,		'check # jobs done, #2' );

my @result = $pool->result_dontwait( $jobid1 );
ok( !@result or (join('',@result) eq 'ihg'), 'check result_dontwait' );

@result = $pool->result( $jobid2 );
is( join('',@result),'mlk',		'check result' );

my $jobid3 = $pool->remove;
cmp_ok( $jobid3,'==',3,			'check third jobid' );

@result = $pool->result( $jobid3 );
my @pre = @{shift @result};
is( join('',@pre,'/',@result),'cba/abc', 'check result remove' );

cmp_ok( scalar($pool->workers),'==',4,	'check number of workers, #5' );
cmp_ok( scalar($pool->removed),'==',6,	'check number of removed, #2' );

$pool->shutdown;
cmp_ok( scalar($pool->workers),'==',0,	'check number of workers, #6' );
cmp_ok( scalar($pool->removed),'==',10,	'check number of removed, #3' );
cmp_ok( $pool->todo,'==',0,		'check # jobs todo, #3' );
cmp_ok( $pool->done,'==',3,		'check # jobs done, #3' );

sub pre {
  my $self = shift;
  reverse @_;
}

sub do {
  my $self = shift;
  my @pre = $self->pre;
  reverse @_;
}

sub post {
  my $self = shift;
  my @pre = $self->pre;
  \@pre,@_;
}
