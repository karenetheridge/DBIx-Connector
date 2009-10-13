#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 48;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Get a connection';

my $module = Test::MockModule->new($CLASS);

# Test with no cached dbh.
$module->mock( _connect => sub {
    pass '_connect should be called';
    $module->original('_connect')->(@_);
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok $dbh->{AutoCommit}, 'We should not be in a txn';
ok !$conn->{_in_run}, '_in_run should be false';

# Set up a DBI mocker.
my $dbi_mock = Test::MockModule->new(ref $dbh, no_auto => 1);
my $ping = 0;
$dbi_mock->mock( ping => sub { ++$ping } );

is $conn->{_dbh}, $dbh, 'The dbh should be cached';
is $ping, 0, 'No pings yet';
ok $conn->connected, 'We should be connected';
is $ping, 1, 'Ping should have been called';
ok $conn->txn_run(sub {
    is $ping, 2, 'Ping should have been called before the txn_run';
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok !$conn->{AutoCommit}, 'We should be in a txn';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    is $ping, 2, 'ping should not have been called again';
}), 'Do something with no cached handle';
$module->unmock( '_connect');
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';

# Test with cached dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->txn_run(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The cached handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    is $_, $dbh, 'Should have dbh in $_';
    $ping = 0;
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    $ping = 1;
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with cached handle';
ok $dbh->{AutoCommit}, 'New transaction should be committed';

# Test the return value.
ok my $foo = $conn->txn_run(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->txn_run(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test an exception.
eval {  $conn->txn_run(sub { die 'WTF?' }) };
ok $@, 'We should have died';
ok $dbh->{AutoCommit}, 'New transaction should rolled back';

# Test args.
ok $dbh = $conn->dbh, 'Get the new handle';
$conn->txn_run(sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through';
}, qw(1 2 3));

# Make sure nested calls work.
$conn->txn_run(sub {
    my $dbh = shift;
    ok !$conn->{AutoCommit}, 'We should be in a txn';
    local $dbh->{Active} = 0;
    $conn->txn_run(sub {
        isnt shift, $dbh, 'Nested txn_run should not get inactive dbh';
        ok !$conn->{AutoCommit}, 'Nested txn_run should be in the txn';
    });
});

# Make sure that it does nothing transactional if we've started the
# transaction.
$dbh = $conn->dbh;
my $driver = $conn->driver;
$driver->begin_work($dbh);
ok !$dbh->{AutoCommit}, 'Transaction should be started';
$conn->txn_run(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'We should have the same database handle';
    is $_, $dbh, 'It should also be in $_';
    $ping = 0;
    local $ENV{FOO} = 1;
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    $ping = 1;
    ok !$dbha->{AutoCommit}, 'Transaction should still be going';
});
ok !$dbh->{AutoCommit}, 'Transaction should stil be live after txn_run';
$driver->rollback($dbh);

# Make sure nested calls when ping returns false.
$conn->txn_run(sub {
    my $dbh = shift;
    ok !$conn->{AutoCommit}, 'We should be in a txn';
    $dbi_mock->mock( ping => 0 );
    $conn->txn_run(sub {
        is shift, $dbh, 'Nested txn_run should get same dbh, even though inactive';
        ok !$conn->{AutoCommit}, 'Nested txn_run should be in the txn';
    });
});

