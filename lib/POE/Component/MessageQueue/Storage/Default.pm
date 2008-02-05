package POE::Component::MessageQueue::Storage::Default;

use strict;
use warnings;
use POE::Component::MessageQueue::Storage::Throttled;
use POE::Component::MessageQueue::Storage::DBI;
use POE::Component::MessageQueue::Storage::FileSystem;
use POE::Component::MessageQueue::Storage::Memory;
use POE::Component::MessageQueue::Storage::Complex;
use DBI;

use constant META_SCHEMA => <<'EOF';
CREATE TABLE meta
(
	key   varchar(255) primary key,
	value varchar(255)
);
EOF

use constant MESSAGES_SCHEMA => <<'EOF';
CREATE TABLE messages
(
	message_id  varchar(255) primary key,
	destination varchar(255) not null,
	persistent  char(1) default 'Y' not null,
	in_use_by   int,
	body        text,
	timestamp   int,
	size        int
);

CREATE INDEX id_index          ON messages ( message_id(8) );
CREATE INDEX timestamp_index   ON messages ( timestamp );
CREATE INDEX destination_index ON messages ( destination );
CREATE INDEX in_use_by_index   ON messages ( in_use_by );

EOF

# Hopefully, this will make adding new changes that break db compatability a
# little easier.  Change the database schema above, then add a check for your
# version like the examples below.
sub _upgrade
{
	my $dbh = shift;
	my @versions = ('0.1.7', '0.1.8');

	# Funny lexical scoping rules require this to be an anonymous sub or weird
	# things will happen with $dbh
	my $meta_version = sub {
		my $check_version = shift;
		my $version;
		eval {
			($version) = $dbh->selectrow_array(
				"SELECT value FROM meta WHERE key = 'version'"
			);
		};
		return (!$@) && ($version ge $check_version);
	};

	# These should return true if the test passes (no upgrade needed)
	my %tests = (
		# The meta-table was added in 0.1.8, so we can't use that...
		'0.1.7' => sub {
			eval {
				$dbh->selectrow_array("SELECT timestamp, size FROM messages LIMIT 1");
			};
			return (!$@);
		},
		'0.1.8' => sub { $meta_version->('0.1.8') },
	);

	my %repairs = (
		'0.1.7' => sub {
			$dbh->do('ALTER TABLE messages ADD COLUMN timestamp INT');
			$dbh->do('ALTER TABLE messages ADD COLUMN size      INT');
		},
		'0.1.8' => sub {
			# 0.1.8 adds a meta table for version info
			$dbh->do( META_SCHEMA );
			$dbh->do(q{INSERT INTO meta (key, value) VALUES ('version', '0.1.8')});

			# SQLite doesn't have a syntax for modifying column types on primary
			# keys, and 1.8->1.9 made message_id a text field.

			# Rename old table and create new one
			$dbh->do('ALTER TABLE messages RENAME TO old_messages');
			$dbh->do( MESSAGES_SCHEMA );

			# Dump old table into new table
			my $columns = q{
				message_id, destination, persistent, 
				in_use_by,  body, timestamp, size
			};

			$dbh->do(qq{
				INSERT INTO messages ( $columns ) 
				SELECT $columns FROM old_messages
			});

			# Delete old table
			$dbh->do('DROP TABLE old_messages');
		},
	);

	my $do_repairs = 0;
	foreach my $ver (@versions)
	{
		unless ($do_repairs) 
		{
			my $success = $tests{$ver}->();
			unless ($success) 
			{
				$dbh->begin_work();
				print STDERR "WARNING: User database is older than $ver.\n";
				print STDERR "WARNING: Performing in-place upgrade...";
				$do_repairs = 1;
			}
		}

		if ($do_repairs)
		{
			eval { $repairs{$ver}->() };
			if ($@)
			{
				$dbh->rollback();
				die "encountered errors: $!: rolling back.\n";
			}
		}
	}
	if ($do_repairs)
	{
		$dbh->commit();
		print STDERR "upgrade complete.\n";
	}
}

sub _make_db
{
	my ($file, $dsn, $username, $password) = @_;
	my $db_exists = (-f $file);
	my $dbh = DBI->connect(
		$dsn, 
		$username, 
		$password, 
		{ RaiseError => 1 }
	);

	if ( $db_exists )
	{
		_upgrade($dbh);
	}
	else
	{
		$dbh->do( MESSAGES_SCHEMA );
		$dbh->do( META_SCHEMA );
		$dbh->do(q{INSERT INTO meta (key, value) VALUES ('version', '0.1.8')});
	}
	$dbh->disconnect();
}

sub new 
{
	my $class = shift;
	my $args = shift;

	my $data_dir = $args->{data_dir} || die "No data dir.";

	(-d $data_dir)    ||
		mkdir $data_dir ||
		die "Couldn't make data dir '$data_dir': $!";

	my $db_file     = "$data_dir/mq.db";
	my $db_dsn      = "DBI:SQLite:dbname=$db_file";
	my $db_username = q();
	my $db_password = q();

	_make_db($db_file, $db_dsn, $db_username, $db_password);

	# We don't bless anything because we're just returning a Complex...
	return POE::Component::MessageQueue::Storage::Complex->new({
		timeout         => $args->{timeout} || 4,	

		front_store     => $args->{front_store} ||
			POE::Component::MessageQueue::Storage::Memory->new(),

		back_store      => POE::Component::MessageQueue::Storage::Throttled->new({
			storage => POE::Component::MessageQueue::Storage::FileSystem->new({
				info_storage    => POE::Component::MessageQueue::Storage::DBI->new({
					dsn             => $db_dsn,
					username        => $db_username,
					password        => $db_password,
				}),
				data_dir        => $data_dir,
			}),
			throttle_max    => $args->{throttle_max},
		}),
	});
}

1;

=pod

=head1 NAME

POE::Component::MessageQueue::Storage::Default -- The default storage engine (based on Complex), recommended for the most common case and used by mq.pl.

=head1 SYNOPSIS

  use POE;
  use POE::Component::MessageQueue;
  use POE::Component::MessageQueue::Storage::Default;
  use strict;

  my $DATA_DIR = '/tmp/perl_mq';

  POE::Component::MessageQueue->new({
    storage => POE::Component::MessageQueue::Storage::Default->new({
      data_dir     => $DATA_DIR,
      timeout      => 4,
      throttle_max => 2,

      # Alternative memory store available!
      #front_store => POE::Component::MessageQueue::Storage::BigMemory->new(),
    })
  });

  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

This storage engine combines all the other provided engines.  It uses
L<POE::Component::MessageQueue::Storage::Memory> as the "front-end storage" and 
L<POE::Component::MessageQueue::Storage::FileSystem> as the "back-end storage"
for L<POE::Componenet::MessageQueue::Storage::Complex> and provides some other
sensible and recommended defaults, though you can override them in most cases. 
Message are initially put into the front-end storage and will be moved into the 
backend storage after a given number of seconds (defaults to 4).

The L<POE::Component::MessageQueue::Storage::FileSystem> component used 
internally uses L<POE::Component::MessageQueue::Storage::DBI> with a 
L<DBD::SQLite> database. It is also throttled via 
L<POE::Component::MessageQueue::Storage::Throttled>.

This is the recommended storage engine.  It should provide the best performance
while (if configured sanely) still providing a reasonable amount of persistence
with little risk of eating all your memory under high load.  This is also the 
only storage backend to correctly honor the persistent flag and will only 
persist those messages with it set.

=head1 CONSTRUCTOR PARAMETERS

=over 2

=item data_dir => SCALAR

The directory to store the SQLite database file and the message bodies.

=item throttle_max => SCALAR

The max number of messages that can be sent to the DBI store at once.  
This value is passed directly to the underlying 
L<POE::Component::MessageQueue::Storage::Throttled>.

=item front_store => SCALAR

An optional reference to a storage engine to use as the front store instead of
Storage::Memory.  If you anticipate a high number of messages making their way
into the front store (five thousand or more), or are experiences high loads and
longer-than-anticpated waits for messages to make it out of the front store, 
consider overriding the front store to
L<POE::Component::MessageQueue::Storage::BigMemory>, which uses a different
data structure that is optimized for large message loads.

=back

=head1 SEE ALSO

L<DBI>,
L<DBD::SQLite>

I<Other storage engines:>

L<POE::Component::MessageQueue>,
L<POE::Component::MessageQueue::Storage>,
L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::BigMemory>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::Generic>,
L<POE::Component::MessageQueue::Storage::Generic::DBI>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>

