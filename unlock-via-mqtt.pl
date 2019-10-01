#!/usr/bin/perl
use strict;
use autodie;

use Net::MQTT::Simple;

my $mqtt = Net::MQTT::Simple->new("mosquitto.space.revspace.nl");

my %opt_in  = do "/home/pi/doorduino/opt-in.conf.pl";
my %opt_out = do "/home/pi/doorduino/opt-out.conf.pl";

die "Can't write to device $opt_in{dev}"  if not -w $opt_in{dev};
die "Can't write to device $opt_out{dev}" if not -w $opt_out{dev};
die "Opt-in door is not a fake door"  if not $opt_in{skip_access};
die "Opt-out door is not a fake door" if not $opt_out{skip_access};

$mqtt->subscribe(
	# Opzettelijk geen wildcards of parsing. Extra hard-coding voor
	# paranoide beveiliging om te voorkomen dat een andere deur
	# kan worden geopend.

	"revspace-local/doorduino/opt-in/unlock" => sub {
		my ($topic, $message) = @_;

		warn "$topic => $message";
		
		open my $dev, ">", $opt_in{dev};
		print $dev "A\n";
		close $dev;
	},
	"revspace-local/doorduino/opt-out/unlock" => sub {
		my ($topic, $message) = @_;

		warn "$topic => $message";

		open my $dev, ">", $opt_out{dev};
		print $dev "A\n";
		close $dev;
	},
);

while (1) {
	$mqtt->tick(1);
}
