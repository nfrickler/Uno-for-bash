#!/usr/bin/perl
use strict;
use warnings;

package UnoObject;
use List::Util 'shuffle';
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw();


# ######################### player/game handling ######################## #

# init all_cards
sub initCards {
	my ($self, $gametype) = @_;
	$gametype //= 0;
	$self->{'all_cards'} = {};

	my $i;
	my $curindex = 0;
	my @c_colors = ("y", "r", "g", "b");
	my @c_nums = ("1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "r", "z");
	for (@c_colors) {
		my $curcolor = $_;
		$self->{'all_cards'}{($curindex++)} = $curcolor."0";
		for (@c_nums) {
			$self->{'all_cards'}{($curindex++)} = $curcolor.$_;
			$self->{'all_cards'}{($curindex++)} = $curcolor.$_;
		}
	}
	for ($i = 4; $i > 0; $i--) {
		$self->{'all_cards'}{($curindex++)} = "sz";
	}
	for ($i = 4; $i > 0; $i--) {
		$self->{'all_cards'}{($curindex++)} = "sf";
	}
}

# new
# create new UnoObject
sub new {
	# init data
	my $obj = {	player => {},
				current => {player => undef,
							color => undef,
							direction => 1,
							drawsum => 0,
							can_pass => 0,
							},
				c_available => [],
				c_set => [],
				Server => undef,
				all_cards => {},
	};
	bless $obj, 'UnoObject';
	return $obj;
}

# setServer
# set server for object
sub setServer {
	my ($self, $Server) = @_;
	$self->{'Server'} = $Server if $Server;
	return 1;
}

# addPlayer
# add player to game
sub addPlayer {
	my ($self, $player, $next, $prev) = @_;

	# add
	$self->{'player'}{$player} = {cards => [],
								  newcards => [],
								  'next' => $next,
								  prev => $prev,
							  	  uno => 0};

	return 1;
}

# deletePlayer
# delete player from game
sub deletePlayer {
	my ($self, $player) = @_;
	return 0 unless defined $self->{'player'}{$player};

	# change current if neccessary
	$self->nextPlayer() if ($self->{'current'}{'player'} eq $player);

	# change links
	my $player_prev = $self->{'player'}{$player}{'prev'};
	my $player_next = $self->{'player'}{$player}{'next'};
	$self->{'player'}{$player_prev}{'next'} = $player_next;
	$self->{'player'}{$player_next}{'prev'} = $player_prev;

	# delete player
	$self->{'player'}{$player} = undef;
	delete $self->{'player'}{$player};

	$self->{'Server'}->printToAll("#Player '$player' has left the game.");
	return 1;
}

# startGame
# start new game
sub startGame {
	my ($self, $gametype) = @_;

	# init cards
	$self->initCards($gametype);
	$self->{'c_available'} = $self->mixCards(keys %{$self->{'all_cards'}});

	# share all_cards with players
	my $all_cards_amount = scalar(keys %{$self->{'all_cards'}});
	my $share_cards = "";
	for my $key (0 .. ($all_cards_amount - 1)) {
		$share_cards.= "|".$self->{'all_cards'}{$key};
	}
	$self->{'Server'}->printToAll(substr($share_cards, 1));

	# give cards to players
	for my $key (keys %{$self->{'player'}}) {
		$self->giveCards($key, 7);
	}

	# get start-card
	my $alarm = 9;
	until (scalar(@{$self->{'c_set'}}) > 0 and $self->{'all_cards'}{@{$self->{'c_set'}}[0]} !~ /^s/) {
		push @{$self->{'c_set'}}, shift @{$self->{'c_available'}};
		$alarm++;
		die "Could not get valid start-card!\n" if $alarm < 1;
	}

	# get random start-player
	my @players = keys %{$self->{'player'}};
	$self->{'current'}{'player'} = @players[int(rand($#players))];
	$self->{'Server'}->printToAll("#Game has started - Much fun!");

	return 1;
}

# sendUpdate
# send updates to all players
sub sendUpdate {
	my ($self) = @_;

	for my $player (keys %{$self->{'player'}}) {
		my $output;

		# current card
		$output.= 'card='.$self->{'c_set'}[0].",";

		# send extra-infos
		my @tmp = map {$_.'='.$self->{'current'}{$_} if defined $self->{'current'}{$_}} keys %{$self->{'current'}};
		$output.= join(',', @tmp).';';

		# send new cards
		if ($self->{'player'}{$player}{'newcards'}) {
			$output.= join(',', @{$self->{'player'}{$player}{'newcards'}});	

			# add new cards to player cards
			push @{$self->{'player'}{$player}{'cards'}}, @{delete $self->{'player'}{$player}{'newcards'}};
		}

		# send to server
		$self->{'Server'}->printTo($player, $output);
	}

	# send amount of cards of each player...
	my $output2 = '';
	for my $player (keys %{$self->{'player'}}) {
		my $tmp = ($self->{'player'}{$player}{'uno'}) ? '+' : '';
		$output2.= $player."=".$self->getCardAmount($player).$tmp." ";
	 } 
	$self->{'Server'}->printToAll($output2);

	return 1;
}


# ########################### game itself ####### ######################## #

# drawCards
# draw cards (one or amount of drawsum)
sub drawCards {
	my ($self, $player) = @_;

	# said uno properly?
	$self->checkUno();

	# is current user?
	return 0 unless (defined $player
						and $player eq $self->{'current'}{'player'});

	# get amount
	my $amount = ($self->{'current'}{'drawsum'}) ? $self->{'current'}{'drawsum'} : 1;
	$self->{'current'}{'drawsum'} = 0;
	print "Player '$player' has to draw $amount cards\n";

	# give cards to current player
	$self->giveCards($self->{'current'}{'player'}, $amount);

	$self->{'current'}{'can_pass'} = 1;
	return 1;
}

# giveCards
# give cards to player
sub giveCards {
	my ($self, $player, $number) = @_;
	$self->{'player'}{$player}{'uno'} = 0;

	# have to mix cards first?
	unless ($number <= scalar(@{$self->{'c_available'}})) {
		my $topcard = shift @{$self->{'c_set'}};
		push @{$self->{'c_available'}}, @{$self->{'c_set'}};
		$self->{'c_set'} = ($topcard);
	}

	# give cards
	for (1 .. $number) {
		my $card = shift @{$self->{'c_available'}};
		push @{$self->{'player'}{$player}{'newcards'}}, $card;
	}
	$self->{'Server'}->printToAll("#'$player' got $number new cards.");	

	return 1;
}

# setCard
# player is setting card
# return true - will go on with next player
# 		 false - will stay with current player
sub setCard {
	my ($self, $player, $card, $color) = @_;
	$card = int($card);

	# validate input
	unless ($self->{'player'}{$player}
			and $self->{'all_cards'}{$card}) {
		# player or card do not exist!

		return 0;
	}

	# check, if "uno" has been said properly
	$self->checkUno();

	# check, if card ok
	unless ($self->canSetCard($player, $card)) {
		# invalid card!
		print "Invalid card!\n";

		# draw new card
		push @{$self->{'player'}{$player}{'newcards'}}, $card if ($self->isPlayerCard($player, $card));
		$self->deletePlayerCard($player, $card);

		# is current player and has to draw?
		if ($player eq $self->{'current'}{'player'}
				and $self->{'current'}{'drawsum'} > 0) {
			$self->drawCards($player);
			return 0;
		}

		# is current player?
		return 0 if ($player ne $self->{'current'}{'player'});

		# give one extra card
		$self->giveCards($player, 1);
		return 1;
	}
	print "Card ok\n";

	# set card
	unshift @{$self->{'c_set'}}, $card;
	$self->deletePlayerCard($player, $card);

	# update game-data 
	$self->{'current'}{'player'} = $player;
	$self->{'current'}{'color'} = '';

	# handle actions following card
	if ($self->{'all_cards'}{$card} =~ /a$/i) {
		print "Skip next player\n";
		$self->a_skipNext();
	}
	elsif ($self->{'all_cards'}{$card} =~ /r$/i) {
		print "Change direction\n";
		$self->a_retour();
	}
	elsif ($self->{'all_cards'}{$card} =~ /sz$/i) {
		print "4 more cards to draw\n";
		$self->a_drawFour($color);
	}
	elsif ($self->{'all_cards'}{$card} =~ /z$/i) {
		print "2 more cards to draw\n";
		$self->a_drawTwo();
	}
	elsif ($self->{'all_cards'}{$card} =~ /f$/i) {
		print "What color do you want?\n";
		$self->a_chooseColor($color);
	}

	return 1;
}

# pass to next player
sub passToNext {
	my ($self, $player) = @_;

	# is current player?
	if ($self->{'current'}{'player'} ne $player) {
		$self->{'Server'}->printTo($player, "# It's not your turn!");
		return 0;
	}

	# check, if player can pass
	unless ($self->{'current'}{'can_pass'}) {
		$self->{'Server'}->printTo($player, "# You can't pass to next player!");
		return 0;
	}

	$self->{'Server'}->printToAll("# '$player' has passed...");
	return 1;
}

# nextPlayer
# go on to next player
sub nextPlayer {
	my $self = shift;

	# is winner?
	my $player_num = scalar( keys %{$self->{'player'}});
	if ($player_num <= 1
		or (scalar(@{$self->{'player'}{$self->{'current'}{'player'}}{'cards'}}) == 0
			and (!$self->{'player'}{$self->{'current'}{'player'}}{'newcards'}
				or scalar(@{$self->{'player'}{$self->{'current'}{'player'}}{'newcards'}}) == 0
				)
			)
	) {
		# congratulations!
		return 0;
	}

	# go to next player
	$self->{'current'}{'player'} = ($self->{'current'}{'direction'} > 0) ? $self->{'player'}{$self->{'current'}{'player'}}{'next'} : $self->{'player'}{$self->{'current'}{'player'}}{'prev'};
	$self->{'current'}{'can_pass'} = 0;

	print "Go on with next player\n";
	return 1;
}

# canSetCard
# check, if player can set card
sub canSetCard {
	my ($self, $player, $card) = @_;

	# is card belonging to player?
	return 0 unless $self->isPlayerCard($player, $card);

	# is current player?
	if ($self->{'current'}{'player'} eq $player) {
		# is current player

		# has to draw?
		if ($self->{'current'}{'drawsum'}) {
			return 1 if ($self->{'all_cards'}{@{$self->{'c_set'}}[0]} =~ /^sz/i
						and $self->{'all_cards'}{$card} =~ /^sz/i);
			return 1 if ($self->{'all_cards'}{$card} =~ /z$/);
			print "Either another +2/+4 or draw!\n";
			return 0;
		}

		# is special card?
		return 1 if ($self->{'all_cards'}{$card} =~ /^s/i);

		# is same color
		my $color = substr($self->{'all_cards'}{$self->{'c_set'}[0]},0,1);
		return 1 if ($self->{'all_cards'}{$card} =~ /^$color/);

		# is color wished by last special-card?
		my $curcolor = $self->{'current'}{'color'};
		return 1 if ($self->{'all_cards'}{@{$self->{'c_set'}}[0]} =~ /^s/
						and $self->{'all_cards'}{$card} =~ /^$curcolor/);

		# is same number?
		my $type = substr($self->{'all_cards'}{$self->{'c_set'}[0]},1,1);
		return 1 if ($self->{'all_cards'}{$card} =~ /$type$/);

	} else {
		# its not players turn...

		# check, if cards are identical
		if ($self->{'all_cards'}{$self->{'c_set'}[0]} eq $self->{'all_cards'}{$card}) {
			return 1;
		}
	}
	return 0;
}


# a_skipNext
# skip next player
sub a_skipNext {
	my $self = shift;

	# next player
	$self->nextPlayer();
	$self->{'Server'}->printToAll("#Next player will be skipped");

	return 1;
}

# a_retour
# retour action
sub a_retour {
	my $self = shift;

	# change direction
	$self->{'current'}{'direction'} *= -1;
	$self->{'Server'}->printToAll("#Direction changed");

	return 1;
}

# a_drawTwo
# draw to cards
sub a_drawTwo {
	my $self = shift;

	# enlarge drawsum
	$self->{'current'}{'drawsum'}+= 2;
	$self->{'Server'}->printToAll("#".$self->{'current'}{'drawsum'}." cards are looking for new owner...");

	return 1;
}

# a_drawFour
# draw four cards
sub a_drawFour {
	my ($self, $color) = @_;

	# set color
	$self->a_chooseColor($color);

	# enlarge drawsum
	$self->{'current'}{'drawsum'}+= 4;
	$self->{'Server'}->printToAll("#".$self->{'current'}{'drawsum'}." cards are looking for new owner...");

	return 1;
}

# a_chooseColor
# choose color action
sub a_chooseColor {
	my ($self, $color) = @_;

	# set current color
	$self->{'current'}{'color'} = ($color) ? $color : 'r';
	print "New color will be: '", $self->{'current'}{'color'},"'\n";
	$self->{'Server'}->printToAll("#New color is '".$self->{'current'}{'color'}."'");

	return 1;
}

# sayUno
# player says uno
sub sayUno {
	my ($self, $player) = @_;

	# has only 1 card?
	unless ($self->getCardAmount($player) == 1) {
		$self->giveCards($player, 1);
		$self->{'Server'}->printToAll("#'$player' have said 'uno' at the wrong time");	
		return 0;
	}

	$self->{'Server'}->printToAll("#'$player' have said 'uno'");
	$self->{'player'}{$player}{'uno'} = 1;
	return 1;
}

# checkUno
# check, if all players have said uno properly
sub checkUno {
	my $self = shift;

	# loop through players
	for my $pl (keys %{$self->{'player'}}) {
		if ($self->getCardAmount($pl) == 1 and !$self->{'player'}{$pl}{'uno'}) {
			# forgot "uno"
			$self->giveCards($pl, 2);
			$self->{'Server'}->printTo($pl, "#Forgot uno");
			$self->{'Server'}->printToAll("#'$pl' have forgotten to say 'uno'");
			$self->{'player'}{$pl}{'uno'} = 1;
		}
		if ($self->{'player'}{$pl}{'uno'} and $self->getCardAmount($pl) > 1) {
			# said "uno", but more than one card
			$self->giveCards($pl, 1);
			$self->{'Server'}->printTo($pl, "#Incorrect uno");
			$self->{'player'}{$pl}{'uno'} = 0;
		}
	}

	return 1;
}


# ########################### helper functions ###################### #

# mixCards
# mix cards
sub mixCards {
	my $self = shift;
	my @arr = shuffle(@_);
	return \@arr;
}

# deletePlayerCard
# delete card from player
sub deletePlayerCard {
	my ($self, $player, $card) = @_;

	# delete card
	my @allmycards = @{$self->{'player'}{$player}{'cards'}};
	for (0 .. $#allmycards) {
		next unless defined $allmycards[$_];
		if ($allmycards[$_] == $card) {
			delete ${$self->{'player'}{$player}{'cards'}}[$_]; 
			last;
		}
	}

	return 1;
}

# isPlayerCard
# is card belonging to player?
sub isPlayerCard {
	my ($self, $player, $card) = @_;

	# go through all cards
	for (@{$self->{'player'}{$player}{'cards'}}) {
		return 1 if (defined $_ and $_ == $card);
	}

	return 0;
}

# getCardAmount
# get amount of cards of one player
sub getCardAmount {
	my ($self, $player) = @_;
	my $amount = 0;
	for (@{$self->{'player'}{$player}{'cards'}}) {
		next unless (defined $_ and /\d+/);
		$amount++;
	}
	return $amount;
}

# getCardPoints
# get points of card
sub getCardPoints {
	my ($self, $card) = @_;

	return 20 if $self->{'all_cards'}{$card} =~ /r$/;
	return 20 if $self->{'all_cards'}{$card} =~ /a$/;
	return 20 if $self->{'all_cards'}{$card} =~ /z$/;
	return 50 if $self->{'all_cards'}{$card} =~ /^sf$/;
	return 70 if $self->{'all_cards'}{$card} =~ /^sz$/;

	return int(substr($self->{'all_cards'}{$card}, 1));
}

# quitGame
# quit game
sub quitGame {
	my $self = shift;

	# calculate card-sum
	my $output = "";
	for my $player (keys %{$self->{'player'}}) {
		my $sum = 0;

		for (@{$self->{'player'}{$player}{'cards'}}) {
			$sum+= $self->getCardPoints($_) if defined $_;
		}

		$output.= $player."=".$sum." ";
	}

	# send ranking to players
	$self->{'Server'}->printToAll($output);
	$self->{'Server'}->printToAll("winner=done;");

	return 1;
}

1;
