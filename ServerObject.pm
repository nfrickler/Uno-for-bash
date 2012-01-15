#!/usr/bin/perl
use strict;
use warnings;

package ServerObject;
use IO::Socket;
use IO::Select;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(new startSocket wait printToAll printTo);

# new
# create new ServerObject
sub new {
	my $obj = {	'clients' => undef,
				'socket' => undef,
				'to_read' => undef,
				'to_write' => undef,
				'accept' => 1
	};
	bless $obj, 'ServerObject';
	return $obj;
}

# startSocket
# start new server
sub startSocket {
	my $self = shift;

	# start socket
	$self->{'socket'} = new IO::Socket::INET(LocalHost => $uno_server::uno_host,
									LocalPort => $uno_server::uno_port,
									Proto => 'tcp',
									Listen => 1,
									Reuse => 1,
									Blocking => 0);
	die "Could not open socket ($!)!\n" unless ($self->{'socket'});

	# start listening
	$self->{'to_read'} = new IO::Select();
	$self->{'to_write'} = new IO::Select();
	$self->{'to_read'}->add($self->{'socket'});
	$self->{'to_write'}->add($self->{'socket'});

    # add stdin/out to clients
    STDIN->blocking(0);
    $self->{'clients'}{\*STDIN} = { name => "std",
                        buffer => '', 
                        buffer_out => '', 
                        wait_for_exit => 0,
                        handle => \*STDIN};
    $self->{'to_read'}->add(\*STDIN);

	return 1;
}

# wait
# wait for new input
sub wait {
	my ($self, $finish_only) = @_;

	while (1) {

		# is sth to send?
		my $timeout = undef;
		for my $hndl (keys %{$self->{'clients'}}) {
			if ($self->{'clients'}{$hndl}{'buffer_out'}) {
				$timeout = 0.3;
				last;
			}
		}

		# finish only?
		return 1 if ($finish_only and !$timeout);

		# select all current requests
		my @todo_read = $self->{'to_read'}->can_read($timeout);

		# handle all requests
		for my $hndl (@todo_read) {

			# new client?
			if ($hndl == $self->{'socket'}) {

				# refuse connection
				unless ($self->{'accept'}) {
					next;
				}

				# add client
				my $new_hndl = $hndl->accept();
				$new_hndl->blocking(0);
				$self->{'to_read'}->add($new_hndl);
				$self->{'to_write'}->add($new_hndl);
	
				# add client to clients
				$self->startClient($new_hndl);

				next;
			}

			# read all available data from client
			my $chars = '';
			my $buffer = '';
			while (sysread($hndl, $chars, 1)) {
				$buffer.= $chars;
			}

			# close connection, if empty buffer
			$self->endClient($hndl, 1) unless $buffer;

			# get complete buffer
			$self->{'clients'}{$hndl}{'buffer'}.= $buffer;

			# handle client-request, if complete line
			if ($self->{'clients'}{$hndl}{'buffer'} =~ /\n/) {

				# split input into lines
				my @lines = split(/^/, $self->{'clients'}{$hndl}{'buffer'});

				# save rest in buffer
				$self->{'clients'}{$hndl}{'buffer'} = ($#lines > 0) ? pop(@lines) : '';

				# process each line
				my $return;
				for (@lines) {
					$return = $self->runLine($hndl, $_);
					return 0 if ($return == 100);
					last unless $return;
				}

				($self->endClient($hndl) and next) unless $return;
			}
		}

		# write to clients
		my @todo_write = $self->{'to_write'}->can_write(0.3);
		for my $hndl (@todo_write) {
			next unless defined $self->{'clients'}{$hndl};

			# is output for client?
			if ($self->{'clients'}{$hndl}{'buffer_out'}) {
				$self->{'clients'}{$hndl}{'buffer_out'} =~ s/[\n\s\r]*$//;
				print "# Send to '", $self->{'clients'}{$hndl}{'name'}, "': '",$self->{'clients'}{$hndl}{'buffer_out'},"'\n";
				print $hndl $self->{'clients'}{$hndl}{'buffer_out'};
				$self->{'clients'}{$hndl}{'buffer_out'} = '';
			}

			# close connection?
			$self->endClient($hndl, 1) if ($self->{'clients'}{$hndl}{'wait_for_exit'});
		}
	}

	return 1;
}

# startClient
# start connection to client
sub startClient {
	my ($self, $hndl) = @_;

	# add client to clients
	$self->{'clients'}{$hndl} = { name => undef,
						buffer => '',
						buffer_out => '',
						wait_for_exit => 0,
						handle => $hndl};

	return 1;
}

# runLine
# handle input-line from client
sub runLine {
	my ($self, $hndl, $input) = @_;
	my %client = %{$self->{'clients'}{$hndl}};
	chomp($input);
	$input =~ s/\r//;
	return 1 unless ($input);

	# has name been set?
	unless ($self->{'clients'}{$hndl}{'name'}) {

		# refuse?
		($self->endClient($hndl) and return 5) unless $self->{'accept'}; 

		# get name
		$_ = $input;
		my ($tmp) = /^name=(\S+)/;
		return 3 unless $tmp;

		# check doubles
		for my $curhndl (keys %{$self->{'clients'}}) {
			if (defined $self->{'clients'}{$curhndl}{'name'}
					and $self->{'clients'}{$curhndl}{'name'} eq $tmp) {
				$self->{'clients'}{$hndl}{'buffer_out'}.= "#Error: Name '$tmp' already in use!\n";
				return 1;
			}
		}

		# set name
		$self->{'clients'}{$hndl}{'name'} = $tmp;
	}

	# server-output
	print "# Received from '", $self->{'clients'}{$hndl}{'name'}, "': '$input'\n";

	# run external...
	return 0 unless $self->{'function'};
	return $self->{'function'}($self->{'clients'}{$hndl}{'name'}, $input);
}

# setFunction
# set function to call from newLine
sub setFunction {
	my ($self, $fnkt) = @_;

	$self->{'function'} = $fnkt if $fnkt;
	return 1;
}

# name2hndl
# get hndl for name
sub name2hndl {
	my ($self, $name) = @_;
	return 0 unless $name;

	for my $curhndl (keys %{$self->{'clients'}}) {
		next unless defined $self->{'clients'}{$curhndl};
		next unless defined $self->{'clients'}{$curhndl}{'name'};
		return $curhndl if ($self->{'clients'}{$curhndl}{'name'} eq $name);
	}

	return 0;
}

# printToAll
# print s.th. to all clients
sub printToAll {
	my ($self, $input) = @_;

	for my $curhndl (keys %{$self->{'clients'}}) {
		next if $curhndl eq $self->name2hndl("std");
		next if $self->{'clients'}{$curhndl}{'wait_for_exit'};
		$self->addToBuffer($curhndl, $input);
	}

	return 1;
}

# printTo
# print to person
sub printTo {
	my ($self, $name, $input) = @_;
	my $hndl = $self->name2hndl($name);

	# add to buffer
	$self->addToBuffer($hndl, $input);

	return 1;
}

# getAllNames
# get all names of clients
sub getAllNames {
	my $self = shift;

	my @names;
	for my $curhndl (keys %{$self->{'clients'}}) {
		next if $curhndl eq $self->name2hndl("std");
		next unless ($self->{'clients'}{$curhndl}{'name'});
		push @names, $self->{'clients'}{$curhndl}{'name'};
	}

	return @names;
}

# refuse
# set, if new connections shall 
sub refuse {
	my ($self, $refuse) = @_;

	# set
	$self->{'accept'} = ($refuse) ? 0 : 1;

	return 1;
}

# closeServer 
# shut down server
sub closeServer {
	my $self = shift;

	# finish sending
	$self->wait(1);

	# close all connections
	for my $hndl (keys %{$self->{'clients'}}) {
		next unless defined $self->{'clients'}{$hndl};
		$self->endClient($hndl,1);
	}

	# close server
	$self->{'socket'}->close();

	print "Server closed.\n";
	return 1;
}

# endClient
# end connection to client
sub endClient {
	my ($self, $hndl, $force) = @_;

	if ($force) {
		# inform others, that this person has quit
		$self->runLine($hndl, "left");
		$hndl = $self->{'clients'}{$hndl}{'handle'};
		return 3 unless defined $hndl;

		# delete from clients
		$self->{'to_read'}->remove($hndl);
		$self->{'to_write'}->remove($hndl);
		$hndl->close();
		$self->{'clients'}{$hndl} = undef;
		delete $self->{'clients'}{$hndl};

		print "Client is exiting...\n";
		return 2;
	}

	# softly close connection
	$self->{'clients'}{$hndl}{'wait_for_exit'} = 1;

	# print status
	return 1;
}

# addToBuffer
# add sth to output-buffer
sub addToBuffer {
	my ($self, $hndl, $output) = @_;
	$self->{'clients'}{$hndl}{'buffer_out'}.= $output."\n";
	return 1;
}

1;
