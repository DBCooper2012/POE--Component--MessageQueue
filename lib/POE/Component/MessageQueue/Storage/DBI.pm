
package POE::Component::MessageQueue::Storage::DBI;
use base qw(POE::Component::MessageQueue::Storage);

use POE::Kernel;
use POE::Session;
use POE::Component::EasyDBI;
use POE::Filter::Stream;
use POE::Wheel::ReadWrite;
use IO::File;
use strict;

use Data::Dumper;

sub new
{
	my $class = shift;
	my $args  = shift;

	my $dsn;
	my $username;
	my $password;
	my $options;

	my $use_files;
	my $data_dir;

	if ( ref($args) eq 'HASH' )
	{
		$dsn      = $args->{dsn};
		$username = $args->{username};
		$password = $args->{password};
		$options  = $args->{options};

		# not "straight DBI" options.
		$use_files = $args->{use_files};
		$data_dir  = $args->{data_dir};
	}

	my $self = $class->SUPER::new( $args );

	$self->{message_id} = 0;
	$self->{claiming}   = { };

	# for keeping messages on the FS
	$self->{use_files}   = $use_files;
	$self->{data_dir}    = $data_dir;
	$self->{file_wheels} = { };
	$self->{wheel_to_message_map} = { };

	my $easydbi = POE::Component::EasyDBI->spawn(
		alias    => 'MQ-DBI',
		dsn      => $dsn,
		username => $username,
		password => $password
	);

	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				$_[KERNEL]->alias_set('MQ-Storage')
			},
		},
		object_states => [
			$self => [
				'_init_message_id',
				'_easydbi_handler',
				'_message_to_store',
				'_message_from_store',
				'_store_claim_message',

				'_write_message_to_disk',
				'_read_message_from_disk',
				'_read_input',
				'_read_error',
				'_write_flushed_event'
			]
		]
	);

	# store the sessions
	$self->{easydbi} = $easydbi;
	$self->{session} = $session;

	# clear the state
	$poe_kernel->post( $self->{easydbi},
		do => {
			sql     => 'UPDATE messages SET in_use_by = NULL',
			event   => '_easydbi_handler',
			session => $self->{session}
		}
	);

	# get the initial message id
	$poe_kernel->post( $self->{easydbi},
		single => {
			sql     => 'SELECT MAX(message_id) FROM messages',
			event   => '_init_message_id',
			session => $self->{session}
		}
	);

	return $self;
}

sub get_next_message_id
{
	my $self = shift;
	return ++$self->{message_id};
}

sub store
{
	my ($self, $message) = @_;

	if ( $self->{use_files} )
	{
		# grab the masseg body
		my $body = $message->{body};
		
		# remake the message, but without the body
		my $temp = POE::Component::MessageQueue::Message->new({
			message_id  => $message->{message_id},
			destination => $message->{destination},
			persistent  => $message->{persistent},
			in_use_by   => $message->{in_use_by},
			body        => undef
		});
		$message = $temp;

		# initiate the process
		$poe_kernel->post( $self->{session}, '_write_message_to_disk', $message, $body );
	}

	# push the message into our persistent store
	$poe_kernel->post( $self->{easydbi},
		insert => {
			table   => 'messages',
			hash    => { %$message },
			session => $self->{session},
			event   => '_message_to_store',

			# baggage:
			_message_id  => $message->{message_id},
			_destination => $message->{destination},
		}
	);
}

sub remove
{
	my ($self, $message_id) = @_;

	# remove from file system
	if ( $self->{use_files} )
	{
		if ( exists $self->{file_wheels}->{$message_id} )
		{
			$self->_log( 'debug', "STORE: FILE: Stopping wheels for mesasge $message_id (deleting)" );
			
			my $infos = $self->{file_wheels}->{$message_id};
			my $wheel = $infos->{write_wheel} || $infos->{read_wheel};

			my $wheel_id = $wheel->ID();

			# stop the wheel
			$wheel->shutdown_input();
			$wheel->shutdown_output();

			# mark to actually delete message, but don't do it now, in order
			# to not leak FD's!
			$self->{file_wheels}->{$message_id}->{delete_me} = 1;
		}
		else
		{
			# Actually delete the file, but *only* if there are no open wheels.
			my $fn = "$self->{data_dir}/msg-$message_id.txt";
			$self->_log( 'debug', "STORE: FILE: Deleting $fn" );
			unlink $fn || $self->_log( 'error', "STORE: FILE: Unable to remove $fn: $!" );
		}
	}

	# remove the message from the backing store
	$poe_kernel->post( $self->{easydbi},
		do => {
			sql          => 'DELETE FROM messages WHERE message_id = ?',
			placeholders => [ $message_id ],
			session      => $self->{session},
			event        => '_easydbi_handler'
		}
	);
}

sub claim_and_retrieve
{
	my $self = shift;
	my $args = shift;

	my $destination;
	my $client_id;

	if ( ref($args) eq 'HASH' )
	{
		$destination = $args->{destination};
		$client_id   = $args->{client_id};
	}
	else
	{
		$destination = $args;
		$client_id   = shift;
	}

	if ( $self->{claiming}->{$destination} )
	{
		# we are already attempting to claim a message for this destination!
		return 0;
	}
	else
	{
		# lock temporarily.
		$self->{claiming}->{$destination} = $client_id;
	}

	$poe_kernel->post( $self->{easydbi},
		arrayhash => {
			sql          => 'SELECT * FROM messages WHERE destination = ? AND in_use_by IS NULL ORDER BY message_id ASC LIMIT 1',
			placeholders => [ $destination ],
			session      => $self->{session},
			event        => '_message_from_store',

			# baggage:
			_destination => $destination,
			_client_id   => $client_id
		}
	);

	# let the caller know that this is actually going down.
	return 1;
}

# unmark all messages owned by this client
sub disown
{
	my ($self, $client_id) = @_;

	$poe_kernel->post( $self->{easydbi},
		do => {
			sql          => 'UPDATE messages SET in_use_by = NULL WHERE in_use_by = ?',
			placeholders => [ $client_id ],
			session      => $self->{session},
			event        => 'easydbi_handler',
		}
	);
}

#
# For handling responses from database:
#

sub _init_message_id
{
	my ($self, $kernel, $value) = @_[ OBJECT, KERNEL, ARG0 ];

	$self->{message_id} = $value->{result} || 0;
}

sub _easydbi_handler
{
	my ($self, $kernel, $event) = @_[ OBJECT, KERNEL, ARG0 ];

	if ( $event->{action} eq 'do' )
	{
		my $pretty = join ', ', @{$event->{placeholders}};
		$self->_log( "STORE: DBI: $event->{sql} [ $pretty ]" );
	}
}

sub _message_to_store
{
	my ($self, $kernel, $value) = @_[ OBJECT, KERNEL, ARG0 ];

	my $message_id  = $value->{_message_id};
	my $destination = $value->{_destination};

	$self->_log( "STORE: DBI: Added message $message_id to backing store" );

	if ( defined $self->{message_stored} )
	{
		$self->{message_stored}->( $destination );
	}
}

sub _message_from_store
{
	my ($self, $kernel, $value) = @_[ OBJECT, KERNEL, ARG0 ];

	my $rows        = $value->{result};
	my $destination = $value->{_destination};
	my $client_id   = $value->{_client_id};

	if ( not defined $self->{dispatch_message} )
	{
		die "Pulled message from backstore, but there is no dispatch_message handler";
	}

	my $message;

	if ( defined $rows and scalar @$rows == 1 )
	{
		my $result = $rows->[0];

		$message = POE::Component::MessageQueue::Message->new({
			message_id  => $result->{message_id},
			destination => $result->{destination},
			persistent  => $result->{persistent},
			body        => $result->{body},
			in_use_by   => $client_id
		});

		# claim this message
		$kernel->post( $self->{easydbi},
			do => {
				sql          => "UPDATE messages SET in_use_by = ? WHERE message_id = ?",
				placeholders => [ $client_id, $message->{message_id} ],
				session      => $self->{session},
				event        => '_store_claim_message',

				# backage:
				_destination => $destination,
				_client_id   => $client_id,
			}
		);

	}
	else
	{
		# unlock claiming from this destination
		delete $self->{claiming}->{$destination};

		if ( scalar @$rows > 1 )
		{
			die "ERROR!  Somehow two messages got attached to the same client!\n";
		}
	}

	if ( defined $message and $self->{use_files} )
	{
		# check to see if we even finished writting to disk
		if ( defined $self->{file_wheels}->{$message->{message_id}} )
		{
			$self->_log( "STORE: FILE: Returning message before in store: $message->{message_id}" );

			# get (and remove) the wheel infos
			my $info = delete $self->{file_wheels}->{$message->{message_id}};

			# first, stop the wheel
			my $wheel = $info->{write_wheel};
			$wheel->shutdown_input();
			$wheel->shutdown_output();

			# second, put the body on the message
			$message->{body} = $info->{body};

			# third, remove the map entry
			delete $self->{wheel_to_message_map}->{$wheel->ID()};

			# TEMP: Checking for suspected cause of memory leak.
			$self->_log( 'debug', sprintf('_message_from_store: wheel_to_message_map=%i file_wheels=%i', scalar keys %{$self->{wheel_to_message_map}}, scalar keys %{$self->{file_wheels}}) );

			# finally, distribute the message
			$self->{dispatch_message}->( $message, $destination, $client_id );
		}
		else
		{
			# pull the message body from disk
			$kernel->post( $self->{session}, '_read_message_from_disk',
				$message, $destination, $client_id );
		}
	}
	else
	{
		# call the handler because the message is complete
		$self->{dispatch_message}->( $message, $destination, $client_id );
	}
}

sub _store_claim_message
{
	my ($self, $kernel, $value) = @_[ OBJECT, KERNEL, ARG0 ];

	my $result      = $value->{result};
	my $destination = $value->{_destination};
	my $client_id   = $value->{_client_id};

	# unlock claiming from this destination
	delete $self->{claiming}->{$destination};

	# notify whoaver, that the destination is ready for another client to try to claim
	# a message.
	if ( defined $self->{destination_ready} )
	{
		$self->{destination_ready}->( $destination );
	}
}

#
# For handling disk access
#

sub _write_message_to_disk
{
	my ($self, $kernel, $message, $body) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];

	if ( defined $self->{file_wheels}->{$message->{messages_id}} )
	{
		$self->_log( 'emergency', "POE::Component::MessageQueue::Store::DBI::_write_message_to_disk(): A wheel already exists for this messages $message->{messages_id}!  This should never happen!" );
		return;
	}

	# setup the wheel
	my $fn = "$self->{data_dir}/msg-$message->{message_id}.txt";
	my $fh = IO::File->new( ">$fn" )
		|| die "Unable to save message in $fn: $!";
	my $wheel = POE::Wheel::ReadWrite->new(
		Handle       => $fh,
		Filter       => POE::Filter::Stream->new(),
		FlushedEvent => '_write_flushed_event'
	);

	# initiate the write to disk
	$wheel->put( $body );

	# stash the wheel in our maps
	$self->{file_wheels}->{$message->{message_id}} = {
		write_wheel => $wheel,
		body        => $body
	};
	$self->{wheel_to_message_map}->{$wheel->ID()} = $message->{message_id};

	# TEMP: Checking for suspected cause of memory leak.
	$self->_log( 'debug', sprintf('_write_message_to_disk: wheel_to_message_map=%i file_wheels=%i', scalar keys %{$self->{wheel_to_message_map}}, scalar keys %{$self->{file_wheels}}) );
}

sub _read_message_from_disk
{
	my ($self, $kernel, $message, $destination, $client_id) = @_[ OBJECT, KERNEL, ARG0..ARG2 ];

	if ( defined $self->{file_wheels}->{$message->{messages_id}} )
	{
		$self->_log( 'emergency', "POE::Component::MessageQueue::Store::DBI::_read_message_from_disk(): A wheel already exists for this messages $message->{messages_id}!  This should never happen!" );
		return;
	}

	# setup the wheel
	my $fn = "$self->{data_dir}/msg-$message->{message_id}.txt";
	my $fh = IO::File->new( $fn );
	
	$self->_log( 'debug', "STORE: FILE: Starting to read $fn from disk" );

	# if we can't find the message body.  This usually happens as a result
	# of crash recovery.
	if ( not defined $fh )
	{
		$self->_log( 'warning', "STORE: FILE: Can't find $fn on disk!  Discarding message." );

		# we simply discard the message
		$self->remove( $message->{message_id} );

		return;
	}
	
	my $wheel = POE::Wheel::ReadWrite->new(
		Handle       => $fh,
		Filter       => POE::Filter::Stream->new(),
		InputEvent   => '_read_input',
		ErrorEvent   => '_read_error'
	);

	# stash the wheel in our maps
	$self->{file_wheels}->{$message->{message_id}} = {
		read_wheel  => $wheel,
		message     => $message,
		destination => $destination,
		client_id   => $client_id
	};
	$self->{wheel_to_message_map}->{$wheel->ID()} = $message->{message_id};

	# TEMP: Checking for suspected cause of memory leak.
	$self->_log( 'debug', sprintf('_read_message_from_disk: wheel_to_message_map=%i file_wheels=%i', scalar keys %{$self->{wheel_to_message_map}}, scalar keys %{$self->{file_wheels}}) );
}

sub _read_input
{
	my ($self, $kernel, $input, $wheel_id) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];

	my $message_id = $self->{wheel_to_message_map}->{$wheel_id};
	my $message    = $self->{file_wheels}->{$message_id}->{message};

	$message->{body} .= $input;
}

sub _read_error
{
	my ($self, $op, $errnum, $errstr, $wheel_id) = @_[ OBJECT, ARG0..ARG3 ];

	if ( $op eq 'read' and $errnum == 0 )
	{
		# EOF!  Our message is now totally assembled.  Hurray!

		my $message_id  = $self->{wheel_to_message_map}->{$wheel_id};
		my $infos       = $self->{file_wheels}->{$message_id};
		my $message     = $infos->{message};
		my $destination = $infos->{destination};
		my $client_id   = $infos->{client_id};

		$self->_log( 'debug', "STORE: FILE: Finished reading $self->{data_dir}/msg-$message_id.txt" );

		# send the message out!
		$self->{dispatch_message}->( $message, $destination, $client_id );

		# clear our state
		delete $self->{wheel_to_message_map}->{$wheel_id};
		delete $self->{file_wheels}->{$message_id};

		# TEMP: Checking for suspected cause of memory leak.
		$self->_log( 'debug', sprintf('_read_error: wheel_to_message_map=%i file_wheels=%i', scalar keys %{$self->{wheel_to_message_map}}, scalar keys %{$self->{file_wheels}}) );

		if ( $infos->{delete_me} )
		{
			# NOTE:  I have never seen this called, but it seems theoretically possible
			# and considering the former problem with leaking FD's, I'd rather keep this
			# here just in case.

			my $fn = "$self->{data_dir}/msg-$message_id.txt";
			$self->_log( 'debug', "STORE: FILE: Actually deleting $fn (on read error)" );
			unlink $fn || $self->_log( 'error', "Unable to remove $fn: $!" );
		}
	}
	else
	{
		$self->_log( 'error', "STORE: $op: Error $errnum $errstr" );
	}
}

sub _write_flushed_event
{
	my ($self, $kernel, $wheel_id) = @_[ OBJECT, KERNEL, ARG0 ];

	# remove from the first map
	my $message_id = delete $self->{wheel_to_message_map}->{$wheel_id};

	$self->_log( 'debug', "STORE: FILE: Finished writting message $message_id to disk" );

	# remove from the second map
	my $infos = delete $self->{file_wheels}->{$message_id};

	# TEMP: Checking for suspected cause of memory leak.
	$self->_log( 'debug', sprintf('_write_flushed_event: wheel_to_message_map=%i file_wheels=%i', scalar keys %{$self->{wheel_to_message_map}}, scalar keys %{$self->{file_wheels}}) );

	if ( $infos->{delete_me} )
	{
		# NOTE: If we were actively writting the file when the message to delete
		# came, we cannot actually delete it until the FD gets flushed, or the FD
		# will live until the program dies.

		my $fn = "$self->{data_dir}/msg-$message_id.txt";
		$self->_log( 'debug', "STORE: FILE: Actually deleting $fn (on write flush)" );
		unlink $fn || $self->_log( 'error', "Unable to remove $fn: $!" );
	}
}

1;

