#
# Copyright 2007 David Snopek <dsnopek@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package POE::Component::MessageQueue::Storage::Generic;
use Moose;
use POE;
use POE::Component::Generic 0.1001;
use POE::Component::MessageQueue::Logger;

# We're going to proxy some methods to the generic object.  Yay MOP!
foreach my $method qw(store remove empty disown)
{
	__PACKAGE__->meta->add_method($method, sub {
		my ($self, @args) = @_;
		$self->generic->call(
			$method, 
			{session => $self->session->ID(), event => '_general_handler'},
			@args,
		);		
		return;
	});
}

# Have to do with after we add those methods, or the role will fail.
with qw(POE::Component::MessageQueue::Storage);

has 'alias' => (
	is       => 'ro',
	isa      => 'Str',
	default  => 'MQ-Storage-Generic',
	required => 1,
);

# We lock per destination: this is the set of locked destinations.
has 'claiming' => (
	is      => 'ro',
	isa     => 'HashRef',
  default => sub { {} },
);	

# This is the place for PoCo::Generic to post events back to.
has 'session' => (
	is       => 'rw',
	isa      => 'POE::Session',
);

has 'generic' => (
	is       => 'rw',
	isa      => 'POE::Component::Generic',
);

make_immutable;

# Because PoCo::Generic needs the constructor options passed to it in this
# funny way, we have to set up generic in BUILD.
sub BUILD 
{
	my ($self, $args) = @_;
	my $package = $self->package_name; 

	$self->session(POE::Session->create(
		object_states => [
			$self => [qw(_general_handler _log_proxy _error _start _shutdown)],
		],
	));

	$self->generic(POE::Component::Generic->spawn(
		package => $package, 
		object_options => [%$args],
		packages => {
			$package => {
				callbacks => [qw(
					remove    remove_multiple     remove_all
					store     claim_and_retrieve  storage_shutdown
				)],
				postbacks => [qw(set_log_function)],
			},
		},
		error => {
			session => $self->alias,
			event   => '_error'
		},
		#debug => 1,
		#verbose => 1,
	));

	$self->generic->set_log_function({}, {
		session => $self->alias, 
		event   => '_log_proxy'
	});

	use POE::Component::MessageQueue;
	$self->generic->ignore_signals({}, 
		POE::Component::MessageQueue->SHUTDOWN_SIGNALS);
};

sub package_name
{
	die "Abstract.";
}

sub _start
{
	my ($self, $kernel) = @_[OBJECT, KERNEL];
	$kernel->alias_set($self->alias);
}

sub _shutdown
{
	my ($self, $kernel, $callback) = @_[OBJECT, KERNEL, ARG0];
	$self->generic->shutdown();
	$kernel->alias_remove($self->alias);
	$self->log('alert', 'Generic storage engine is shutdown!');
	$callback->();
}

# For the next two functions:  We only want DBI servicing one claim request at
# a time, so we'll serialize incoming claim requests at this level and send
# them to DBI one at a time as they finish.

sub _qclaim
{
	my ($self, $destination) = @_;
	my $q = $self->claiming->{$destination};
	my $next = shift(@$q);
	unless ($next)
	{
		delete $self->claiming->{$destination};
		return;
	}
	
	$self->generic->claim_and_retrieve(
		{session => $self->session->ID(), event => '_general_handler'},
		$destination, $next->{cid},
		sub {
			$next->{cb}->(@_);
			$self->_qclaim($destination);				
		},
	);
}

sub claim_and_retrieve
{
	my ($self, $destination, $client_id, $dispatch) = @_;

	my $request = {cid => $client_id, cb => $dispatch};
	my $q = $self->claiming->{$destination};

	if ($q)
	{
		push(@$q, $request);
	}
	else
	{
		$self->claiming->{$destination} = [$request];
		$self->_qclaim($destination);
	}
	return;
}

sub storage_shutdown
{
	my ($self, $complete) = @_;
	$self->log('alert', 'Shutting down generic storage engine...');

	# Send the shutdown message to generic - it will come back when it's cleaned
	# up its resources, and we can stop it for reals (as well as stop our own
	# session).  
	$self->generic->yield('storage_shutdown', {}, sub {
		$poe_kernel->post($self->session, '_shutdown', $complete);
	});

	return;
}

sub _general_handler
{
	my ($self, $kernel, $ref, $result) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];

	if ( $ref->{error} )
	{
		$self->log("error", "Generic error: $ref->{error}");
	}
	return;
}

sub _error
{
	my ( $self, $err ) = @_[ OBJECT, ARG0 ];

	if ( $err->{stderr} )
	{
		$self->log('debug', $err->{stderr});
	}
	else
	{
		$self->log('error', sprintf('Generic error:  %s %s %s', 
			$err->{operation}, $err->{errnum}, $err->{errstr}));
	}
	return;
}

sub _log_proxy
{
	my ($self, $type, $msg) = @_[ OBJECT, ARG0, ARG1 ];

	$self->log($type, $msg);
	return;
}

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue::Storage::Generic -- Wraps storage engines that aren't asynchronous via L<POE::Component::Generic> so they can be used.

=head1 SYNOPSIS

  use POE;
  use POE::Component::MessageQueue;
  use POE::Component::MessageQueue::Storage::Generic;
  use POE::Component::MessageQueue::Storage::Generic::DBI;
  use strict;

  # For mysql:
  my $DB_DSN      = 'DBI:mysql:database=perl_mq';
  my $DB_USERNAME = 'perl_mq';
  my $DB_PASSWORD = 'perl_mq';
  my $DB_OPTIONS  = undef;

  POE::Component::MessageQueue->new({
    storage => POE::Component::MessageQueue::Storage::Generic->new({
      package => 'POE::Component::MessageQueue::Storage::DBI',
      options => [{
        dsn      => $DB_DSN,
        username => $DB_USERNAME,
        password => $DB_PASSWORD,
        options  => $DB_OPTIONS
      }],
    })
  });

  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

Wraps storage engines that aren't asynchronous via L<POE::Component::Generic> so they can be used.

Using this module is by far the easiest way to write custom storage engines because you don't have to worry about making your operations asynchronous.  This approach isn't without its down-sides, but on the whole, the simplicity is worth it.

There is only one package currently provided designed to work with this module: L<POE::Component::MessageQueue::Storage::Generic::DBI>.

=head1 METHODS

=over 2

=item package_name

Classes implenting this role are required to provide a "package_name" method
that returns the name of the package to wrap.

=back

=head1 SEE ALSO

L<DBI>,
L<POE::Component::Generic>,
L<POE::Component::MessageQueue>,
L<POE::Component::MessageQueue::Storage>,
L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::Generic::DBI>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>

=cut

