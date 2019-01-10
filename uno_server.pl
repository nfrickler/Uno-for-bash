#!/usr/bin/perl
use strict;
use warnings;

# Load packages from local directory
use File::Basename;
use lib dirname (__FILE__);

package uno_server;
use ServerObject;
use UnoObject;

# any parameter given?
our $uno_host = $ARGV[0] || 'localhost';
our $uno_port = $ARGV[1] || '4321';
my $player_number = $ARGV[2] || 0;
print "Server will listen on $uno_host, Port $uno_port.\n";
print "Will start game, when $player_number players connected...\n" if ($player_number);

# ################  phase 1 (connect) # ###########################

# start server
my $Server = ServerObject->new();
unless ($Server->startSocket()) {
	die "Error: Could not start server!\n";
}

# get new connections
my $admin_player;
$Server->setFunction(\&phase1);
$Server->wait();

sub phase1 {
	my ($name, $input) = @_;

	# set as admin player?
	unless ($admin_player) {
		$admin_player = $name;
		$Server->printTo($name, "#You are the admin.");
	}

	# return if input=name
	if ($input =~ /^name=/) {
		$Server->printToAll("#Player '$name' has joined.");
	}

	# left?
	if ($input =~ /^left/) {
		$Server->printToAll("#Player '$name' has left.");
	}

	# start, if enough player have connected
	if ($player_number) {
		my @player_current = $Server->getAllNames();
		print "Currently ", scalar(@player_current), " player connected.\n";
		return 100 if (scalar(@player_current) >= $player_number);
	}

	# start game?
	return 100 if ($name eq $admin_player and $input =~ m/^start$/);

	return 1;
}

# #################  phase 2 (init) #############################

# refuse new connections
$Server->refuse(1);

# start unoobject
my $Uno = UnoObject->new();
$Uno->setServer($Server);

# add all players to game
my @names = $Server->getAllNames();
@names = sort {$b cmp $a} @names;
for (0 .. $#names) {
	my $next = ($_ == $#names) ? 0 : $_ + 1;
	my $prev = ($_ == 0) ? $#names : $_ - 1;
	$Uno->addPlayer($names[$_], $names[$next], $names[$prev]);
}

# and start game
unless ($Uno->startGame()) {
	die "Error: Could not start game!\n";
}
$Uno->sendUpdate();

# #################  phase 3 (game) ##########################

# handle requests of clients
$Server->setFunction(\&phase3);
$Server->wait();
sub phase3 {
	my ($player, $input) = @_;
	my $is_valid = 0;

	# get color (wished via special-card)
	my $color;
	$color = $2 if ($input =~ s/^(.*),(.*)$/$1/);

	# set card?
	if ($input =~ /^\d+$/) {
		$is_valid = $Uno->setCard($player, $input, $color);
	}

	# has player left?
	elsif ($input =~ /^left/) {
		$Uno->deletePlayer($player);
	}

	# draw cards?
	elsif ($input =~ /^draw/) {
		$is_valid = $Uno->drawCards($player);
	}

	# uno?
 	elsif ($input =~ /^uno/) {
		$Uno->sayUno($player);
	}

	# chat
	elsif ($input =~ s/^#//) {
		$Server->printToAll("##$player: $input");
	}

	# invalid request?
	else {
		print "Received an invalid request!!\n";
	}

	# next player and send update to clients
	my $return = 1;
	$return = $Uno->nextPlayer() if $is_valid;
	$Uno->sendUpdate();

	return 100 unless $return;
	return 1;
}

# end of game
$Uno->quitGame();
$Server->closeServer();

