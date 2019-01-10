#! /usr/bin/perl
use strict;
use warnings;
use IO::Socket;
use IO::Select;
#binmode STDOUT, ':encoding(UTF-8)';

# server-data
my $serveradress= $ARGV[0] || 0;
my $serverport= $ARGV[1] || 0;
my $nick= $ARGV[2] || 0;

# global data
my %player;
my @handkarten=();

# current data
my %current = {
	card => undef,
	color => undef,
	player => undef,
	direction => undef,
	drawsum => undef,
	winner => undef};

# messages
my @game_msgs = ();
my @chatmsgs = ();
my $request = '';

# init card-hash
my (%all_cards, $i);
my $curindex = 0;
my @c_colors = ("y", "r", "g", "b");
my @c_nums = ("1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "r", "z");
for (@c_colors) {
	my $curcolor = $_;
	$all_cards{($curindex++)} = $curcolor."0";
	for (@c_nums) {
		$all_cards{($curindex++)} = $curcolor.$_;
		$all_cards{($curindex++)} = $curcolor.$_;
	}
}
for ($i = 4; $i > 0; $i--) {
	$all_cards{($curindex++)} = "sz";
}
for ($i = 4; $i > 0; $i--) {
	$all_cards{($curindex++)} = "sf";
}

# get server-data
print "\e[m\e[2J\n";
unless ($serveradress and $serverport and $nick) {

	# serveraddress
	print "\e[20;50f"."\e[32mEnter Server adress:\e[31m";
	print "\e[23;50f"."\e[32mEnter Server port:\e[31m";
	print "\e[26;50f"."\e[32mEnter Nickname:\e[31m";
	print "\e[21;50f";

	chomp($serveradress=<STDIN>);
	print "\e[24;50f";
	chomp($serverport=<STDIN>);
	print "\e[27;50f";
	chomp($nick=<STDIN>);
}
print "\e[m\e[2J\n";

# create socket
my $sock = IO::Socket::INET->new(
	PeerAddr => $serveradress,
	PeerPort => $serverport,
	Proto    => 'tcp',
	Timeout  => 20,
	Blocking => 0 )
	or die "\e[2J\e[31m\e[30;50fKonnte nicht mit dem Server (Host: $serveradress, Port: $serverport) verbinden!\e[m\e[f";
my $sel = new IO::Select( $sock );
$sel->add(\*STDIN);
print $sock "name=$nick\n";
unshift @game_msgs, "You connected to $serveradress:$serverport";
unshift @game_msgs, "Your name is $nick.";

# wait for game-start
print "\e[25;50f\e[31;1;40m"."|---------------------------------|";
print "\e[26;50f\e[31;1;40m"."|   Wait for other players...     |";
print "\e[27;50f\e[31;1;40m"."|---------------------------------|";
print "\e[m\n";

# manage input and game
my %tmp;
my $has_started = 0;

MAINLOOP:
while(1) {
	# update screen
	draw() if $has_started;

	# start listening
	my @ready = $sel->can_read();
	foreach my $fh (@ready) {

		# read from socket
		if ($fh == $sock) {

			my $is_on = 0;
			while (my $line = <$fh>) {
				$is_on = 1;
				chomp($line);

				# print messages
				if ($line =~ s/^#//) {
					if ($line =~ s/^#//) {
						unshift @chatmsgs, $line;
						next;
					}
					unshift @game_msgs, $line;
					next;
				}

				$has_started = 1;
				saveData($line);
			}

			# server closed?
			unless ($is_on) {
				close($sock);
				last MAINLOOP;
			}
		}

		# input from user
		else {
			chomp(my $line = <$fh>);
			if ($line =~ /^\d+$/) {

				# get cardid
				$line = int($line);
				my $cardid = (defined $handkarten[$line]) ? $handkarten[$line] : undef;
				next unless defined $cardid;

				# wait for color?
				if ($all_cards{$cardid} =~ /^s/) {
					$tmp{'cardtosend'} = $cardid;
					$request = "What color do you want? (y|g|r|b)";
					next;
				}

				# send to server
				sendCard($cardid);
			}
			elsif ($line =~ /^u(no)?$/) {
				print $sock "uno\n";
			}
			elsif ($line =~ /^d(raw)?$/) {
				print $sock "draw\n";
			}
			elsif ($line =~ /^[yrgb]$/ and defined $tmp{'cardtosend'}) {
				sendCard($tmp{'cardtosend'}, $line);
				$tmp{'cardtosend'} = undef;
			}
			elsif ($line =~ /^s(tart)?$/) {
				print $sock "start\n";
			}

			# send chat-messages
			elsif ($line =~ /^#/) {
				print $sock "$line\n";
			}

			# else
			else {
				unshift @game_msgs, "Invalid input!";
			}
		}
	}

	# my turn?
	if(defined $current{'player'}
			and $current{'player'} eq $nick
			and not defined $tmp{'cardtosend'}
	) {
		# what card to lay?
		$request = "What card?";
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

# saveData
# save input-data
sub saveData { 
	my $input = shift;
	$request = undef;

	# are playernames?
	if ($input !~ /;/) {
		my @tmporary = split(" ", $input);

		%player = ();
		for (@tmporary) {
			my @ttt = split("=", $_);
			my $is_uno = ($ttt[1] =~ s/\+//);
			$player{$ttt[0]} = {'cards' => $ttt[1],
				'uno' => $is_uno};
		}
	}

	# status-data
	else {
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
		push(@handkarten, @tmpcards);
		@handkarten = sort{$a <=> $b}(@handkarten) if (@handkarten);
	}

	return 0;
}

# sendCard
# send card to server
sub sendCard {
	my ($card, $color) = @_;

	# send card to server
	$color = 0 unless ($color);
	print $sock $card.",".$color."\n";

	# remove card from current stack
	@handkarten = grep { $_ != $card } @handkarten;
	@handkarten = sort{$a <=> $b} (@handkarten) if (@handkarten);

	return 1;
}

# draw
# draw current screen
sub draw {
	my $counter = 0;
	print "\e[m\e[2J\n";

	# print frame
	print "\e[".$_.";20f"."|"."\e[".$_.";100f"."|" for (0 .. 40);
	print "\e[40;".$_."f"."-" for (0 .. 120);
	print "\e[28;".$_."f"."_" for (21 .. 99);

	# print cards
	print "\e[1;1f\e[1m Your cards\e[m";
	my $curpos = 3;
	for (0 .. $#handkarten) {
		next unless defined $handkarten[$_];
		my $curcard = $all_cards{$handkarten[$_]};

		# print card
		print "\e[".$curpos.";5f $_)";
		printCard(substr($curcard,0,1), "  ".substr($curcard,1,1)."  ", 10, $curpos);

		# get next position
		$curpos+= 2;
	}

	# print stapel
	my $topcard = (defined $current{'card'}) ? $all_cards{$current{'card'}} : undef;
	printCard(substr($topcard,0,1), "  ".substr($topcard,1,1)."  ", 57, 22) if (defined $topcard); 

	# print additional info
	my $curcolor = substr($topcard, 0, 1);
	$curcolor = $current{'color'} if ($topcard =~ /^s/);
	printCard($curcolor, "   ", 54, 21);
	printCard($curcolor, "  ", 62, 21);
	printCard($curcolor, "  ", 55, 23);
	printCard($curcolor, "   ", 62, 23);
	if ($current{'drawsum'} > 0) {
		print "\e[22;64f To draw: ", $current{'drawsum'}, "!";
	}

	# print players
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

	# print messages
	print "\e[2;21f\e[1m"."UNO"."\e[m";
	$counter = 0;
	for (reverse @game_msgs) {
		print "\e[".(3+$counter).";23f".$_;
		$counter++;
	}
	@game_msgs = splice(@game_msgs, 0, 7);

	# print chat 
	print "\e[30;21f\e[1m"."Chat"."\e[m";
	$counter = 0;
	for (reverse @chatmsgs) {
		print "\e[".(31+$counter).";23f".$_;
		$counter++;
	}
	@chatmsgs = splice(@chatmsgs, 0, 8);

	# print request
	print "\e[26;21f\e[1;37;40m".$request."\e[m" if ($request);

	# set pointer for input
	print "\e[26;22f\n"."Input:";

	return 1;
}

# printCard
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

# printWinner
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

