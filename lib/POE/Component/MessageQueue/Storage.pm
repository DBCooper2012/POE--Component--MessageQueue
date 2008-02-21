#
# Copyright 2007, 2008 David Snopek <dsnopek@gmail.com>
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

package POE::Component::MessageQueue::Storage;
use Moose::Role;
use POE::Component::MessageQueue::Logger;

requires qw(
	storage_shutdown    remove  empty  peek 
	claim_and_retrieve  disown  store  peek_oldest
);

has 'names' => (
	is      => 'rw',
	isa     => 'ArrayRef',
	writer  => 'set_names',
	default => sub { [] },
);

has 'namestr' => (
	is      => 'rw',
	isa     => 'Str',
	default => q{},
);

has 'children' => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} },
);

has 'logger' => (
	is      => 'rw',
	writer  => 'set_logger',
	default => sub { POE::Component::MessageQueue::Logger->new() },
);

sub add_names
{
	my ($self, @names) = @_;
	my @prev_names = @{$self->names};
	push(@prev_names, @names);
	$self->set_names(\@prev_names);
}

after 'set_names' => sub {
	my ($self, $names) = @_;
	while (my ($name, $store) = each %{$self->children})
	{
		$store->set_names([@$names, $name]);
	}
	$self->namestr(join(': ', @$names));
};

sub log
{
	my ($self, $type, $msg, @rest) = @_;
	my $namestr = $self->namestr;
	return $self->logger->log($type, "STORE: $namestr: $msg", @rest);
}

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue::Storage -- Parent of provided storage engines

=head1 DESCRIPTION

The parent class of the provided storage engines.  This is an "abstract" class that can't be used as is, but defines the interface for other objects of this type.

=head1 INTERFACE

=over 2

=item set_logger I<SCALAR>

Takes an object of type L<POE::Component::MessageQueue::Logger> that should be used for logging.

=item store I<SCALAR,CODEREF>

Takes an object of type L<POE::Component::MessageQueue::Message> that should
be stored.  The optional coderef will be called with the stored message as an
argument when storage has completed.  If a message could not be claimed, the
message argument will be undefined.

=item remove I<ARRAYREF,CODEREF>

Takes an arrayref of message_ids to be removed from the storage engine. If a
coderef is supplied, it will be called with an arrayref of the removed
messages after removal.

=item empty I<CODEREF>

Takes an optional coderef argument that will be called with an arrayref of all
the message that were in the store after they have been removed.

=item claim_and_retrieve I<SCALAR, SCALAR, CODEREF>

Takes the destination string and client id.  Claims a message for the given 
client id on the given destination.  When this has been done, the supplied
coderef will be called with the message, destination, and client_id as
arguments.

=item disown I<SCALAR>, I<SCALAR>, I<CODEREF>

Takes a destination and client id.  All messages which are owned by this
client id on this destination should be marked as owned by nobody.  If a
coderef is supplied, it will be called with no arguments when disown has
finished.

=item storage_shutdown I<CODEREF>

Starts shutting down the storage engine.  The supplied coderef will be called
with no arguments when the shutdown has completed.  The storage engine will
attempt to do any cleanup (persisting of messages, etc) before calling the
coderef.

=back

=head1 SEE ALSO

L<POE::Component::MessageQueue>,
L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::Generic>,
L<POE::Component::MessageQueue::Storage::Generic::DBI>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>

=cut
