#! /usr/bin/perl
use strict;
use warnings;

# Uno-Client
#
# Protocol:
# 	All messages are separated by a newinput


package uno_client;
use IO::Socket;
use IO::Select;

# ########################## init ############################### #

# connection
my $host_address	= $ARGV[0] // 0;
my $host_port		= $ARGV[1] // 0;
my $sock;

# player
my $player_name		= $ARGV[2] // "";
my %player;
my @player_cards=();
my $player_tmpcard;

# game
my $game_status = 0;
my %game_cards;
my %current = (	card => undef,
				color => undef,
				player => undef,
				direction => undef,
				drawsum => undef,
				winner => undef
			);

# messages
my @msg_game		= ();
my @msg_chat		= ();
my $msg_request		= "";

# ########################## runtime ############################ #

# start selector
my $sel = new IO::Select( $sock );
STDIN->blocking(0);
$sel->add(\*STDIN);

# connect
connectToHost();

# set nick 
setNick();

MAINLOOP:
while (1) {

	# update screen
	draw();

	my @ready = $sel->can_read();
	foreach my $fh (@ready) {

		# read all input
		my @input;
		my $chars = "";
		my $buffer = "";
		while (sysread($fh, $chars, 1)) {
			$buffer.= $chars;
		}
		@input = split /^/, $buffer;

		# server-connection
		if ($fh eq $sock) {

			# connection lost?
			unless (scalar @input) {
				close($sock);
				last MAINLOOP;
			}

			# handle all inputs
			handleInput($_) for (@input);				
		}

		# std-input
		else {
			handleStdInput($_) for (@input);				
		}
	}

	# my turn?
	if ($game_status < 3) {
		$msg_request = "Waiting for other players to join...";
	}
	elsif ($current{'player'} eq $player_name
			and not defined $player_tmpcard) {
		$msg_request = "What card?";
	}
	elsif ($current{'player'} eq $player_name
			and defined $player_tmpcard) {
		$msg_request = "What colour do you want (r|g|b|y)?";
	}
	else {
		$msg_request = "";
	}
}

# handle end
if (defined $current{'winner'}) {
	printWinner();
	print "Game finished...\n";
	exit 0;
} else {
	print "Connection to server lost!\n";
	exit 1;
}

# ########################## subs ############################### #

# start connection
sub connectToHost {

	# create connection
	$sock = IO::Socket::INET->new(	PeerAddr => $host_address,
									PeerPort => $host_port,
									Proto    => 'tcp',
									Blocking => 0,
								)
	or die "\e[2J\e[31m\e[30;50fKonnte nicht mit dem Server
			(Host: $host_address, Port: $host_port) verbinden!\e[m\e[f";
	$sel->add($sock);
	unshift @msg_game, "You connected to $host_address:$host_port";

}

# set player_namename
sub setNick {

	# set player_name
	print $sock "name=$player_name\n";
	unshift @msg_game, "Your name is $player_name.";
}

# handle input
sub handleInput {
	my ($input) = @_;
	chomp($input);

	# handle chat
	if ($input =~ /^##/) {
		unshift @msg_chat, $input;
	}

	# handle game messages
	elsif ($input =~ /^#/) {
		unshift @msg_game, $input;
	}

	# game_cards info?
	elsif ($input !~ /;/ and $input =~ /\|/) {
		%game_cards = {};
		my $counter = 0;
		print "Got cards\n";
		for (split /\|/, $input) {
			$game_cards{$counter} = $_;
			print "Card: $_ \n";
			$counter++;
		}
		$game_status = 1 if ($game_status < 1);
	}

	# are playernames?
	elsif ($input !~ /;/) {
		my @tmporary = split(" ", $input);

		%player = ();
		for (@tmporary) {
			my @ttt = split("=", $_);
			my $is_uno = ($ttt[1] =~ s/\+//);
			$player{$ttt[0]} = {'cards' => $ttt[1],
								'uno' => $is_uno};
		}
		$game_status = 2 if ($game_status < 2);
	}

	# status-data
	elsif ($input =~ /;/) {
		my @data = split(';', $input);

		# update current-hash
		my @currentdata = split(",", shift @data);
		for (@currentdata) {
			my @tmp = split("=", $_);
			next unless scalar(@tmp) == 2;
			$current{$tmp[0]} = $tmp[1];
		}

		# get new cards
		my @tmpcards = split(/,/, shift @data);
		push(@player_cards, @tmpcards);
		@player_cards = sort{$a <=> $b}(@player_cards) if (@player_cards);

		$game_status = 3 if ($game_status < 3);
	}

	return 1;
}

# send card to server
sub sendCard {
	my ($card, $color) = @_;

	# send card to server
	$color = 0 unless ($color);
	print $sock $card.",".$color."\n";

	# remove card from current stack
	@player_cards = grep { $_ != $card } @player_cards;
	@player_cards = sort{$a <=> $b} (@player_cards) if (@player_cards);

	return 1;
}

# handle input from stdin
sub handleStdInput {
	my ($input) = @_;
	chomp($input);

	# layed card?
	if ($input =~ /^\d+$/) {

		# get cardid
		$input = int($input);
		my $cardid = (defined $player_cards[$input]) ? $player_cards[$input] : undef;
		next unless defined $cardid;

		# wait for color?
		if ($game_cards{$cardid} =~ /^s/) {
			$player_tmpcard = $cardid;
			next;
		}

		# send to server
		sendCard($cardid);
	}

	# command?
	elsif ($input=~ /^u(no)?$/) {
		print $sock "uno\n";
	}
	elsif ($input =~ /^p(ass)?$/) {
		print $sock "pass\n";
	}
	elsif ($input =~ /^d(raw)?$/) {
		print $sock "draw\n";
	}
	elsif ($input =~ /^start$/) {
		print $sock "start\n";
	}

	# said color?
	elsif ($input =~ /^[yrgb]$/ and defined $player_tmpcard) {
		sendCard($player_tmpcard, $input);
		$player_tmpcard = undef;
	}

	# chat message?
	elsif ($input =~ /^#/) {
		print $sock "$input\n";
	}

	# else
	else {
		unshift @msg_game, "Invalid input!";
	}

	return 1;
}

# redraw screen
sub draw {
	my $counter;

	# clear screen
	print "\e[m\e[2J\n";

	# print frame
	print "\e[".$_.";20f"."|"."\e[".$_.";100f"."|" for (0 .. 40);
	print "\e[40;".$_."f"."-" for (0 .. 120);
	print "\e[28;".$_."f"."_" for (21 .. 99);

	if ($game_status > 2) {

		# print cards
		print "\e[1;1f\e[1m Your cards\e[m";
		my $curpos = 3;
		for (0 .. $#player_cards) {
			next unless (defined $player_cards[$_] and defined $game_cards{$player_cards[$_]});
			my $curcard = $game_cards{$player_cards[$_]};

			# print card
			print "\e[".$curpos.";5f $_)";
			printCard(substr($curcard,0,1), "  ".substr($curcard,1,1)."  ", 10, $curpos);

			# get next position
			$curpos+= 2;
		}

		# print stapel
		my $topcard = (defined $current{'card'}) ? $game_cards{$current{'card'}} : undef;
		printCard(substr($topcard,0,1), "  ".substr($topcard,1,1)."  ", 57, 22) if (defined $topcard); 
	
		# print additional info
		if (defined $topcard) {
			my $curcolor = substr($topcard, 0, 1);
			$curcolor = $current{'color'} if ($topcard =~ /^s/);
			printCard($curcolor, "   ", 54, 21);
			printCard($curcolor, "  ", 62, 21);
			printCard($curcolor, "  ", 55, 23);
			printCard($curcolor, "   ", 62, 23);
			if ($current{'drawsum'} > 0) {
				print "\e[22;64f To draw: ", $current{'drawsum'}, "!";
			}
		}
	}

	# print players
	if ($game_status > 1) {

		print "\e[1;102f\e[1m Player\e[m";
		my $spielerpos = 3;
		for my $name (keys %player) {
			my $bgcolor = ($player{$name}{'uno'}) ? '41' : '40';
			print "\e[".$spielerpos.";104f\e[37;1;".$bgcolor."m".$name." (".$player{$name}{'cards'}.")\e[m";

			# mark current player
			if ($name eq $current{'player'}) {
				my $arrow = ($current{'direction'} > 0) ? "d" : "u";
				print "\e[".$spielerpos.";101f $arrow";
			}

			$spielerpos+= 2;
		}
	}

	# print messages
	print "\e[2;21f\e[1m"."UNO"."\e[m";
	$counter = 0;
	for (reverse @msg_game) {
		print "\e[".(3+$counter).";23f".$_;
		$counter++;
	}
	@msg_game = splice(@msg_game, 0, 7);

	# print chat 
	print "\e[30;21f\e[1m"."Chat"."\e[m";
	$counter = 0;
	for (reverse @msg_chat) {
		print "\e[".(31+$counter).";23f".$_;
		$counter++;
	}
	@msg_chat = splice(@msg_chat, 0, 8);

	# print msg_request
	print "\e[26;21f\e[1;37;40m".$msg_request."\e[m" if ($msg_request);

	# set pointer for input
	print "\e[26;22f\n"."Input:";

	return 1;
}

# print card to current position
sub printCard {
	my ($cardcolor, $phrase, $x, $y) = @_;

	# get color of card
	my $color = 0;
	$color = 40 if $cardcolor =~ /^s/;
	$color = 41 if $cardcolor =~ /^r/;
	$color = 42 if $cardcolor =~ /^g/;
	$color = 43 if $cardcolor =~ /^y/;
	$color = 44 if $cardcolor =~ /^b/;
	my $fontcolor = 37;

	# print card
	print "\e[".$y.";".$x."f\e[".$fontcolor.";1;".$color."m\e[".$y.";".$x."f".$phrase;
	print "\e[".$y.";".$x."f\e[m";

	return 1; 
}

# print winner and ranking
sub printWinner {

	print "\e[2J";
	my @sorted = sort { int($player{$a}{'cards'}) <=> int($player{$b}{'cards'}) } keys %player; 

	# print players
	print "\e[1;26f\e[1m Ranking \e[m";
	my $spielerpos = 3;
	my $ranking = 1;
	for my $name (@sorted) {
		my $bgcolor = '40';
		my $fontcolor = '37';
		$bgcolor = '43' if ($ranking == 1);
		$bgcolor = '47' if ($ranking == 2);
		$bgcolor = '41' if ($ranking == 3);
		$fontcolor = '30' if ($ranking == 2);
		print "\e[".$spielerpos.";30f\e[".$fontcolor.";1;".$bgcolor."m ".$ranking.". ".$name." (".$player{$name}{'cards'}.") \e[m";
		print "\n\n";

		$spielerpos+= 2;
		$ranking++;
	}
}

