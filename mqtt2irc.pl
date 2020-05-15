#!/usr/bin/perl -w

use strict;
use v5.28;
use Net::MQTT::Simple;
use Time::HiRes qw(time);

my $mqtt = Net::MQTT::Simple->new("127.0.0.1");

sub mekker {
    my $fn = "/home/bar/saysomething/freenode_revspace";
    open my $fh, ">>", $fn or warn "open: $fn: $!";
    print STDOUT "@_\n";
    print $fh    "@_\n";
}

sub flipdot {
    $mqtt->publish("revspace/flipdot", "@_");
}

my $off;
my $lichtgordijn_start;
$mqtt->subscribe(
        "revspace/doorduino" => sub {
            my ($topic, $message) = @_;
            mekker $message;
        },
        "revspace/doorduino/checked-in" => sub {
            my ($topic, $message) = @_;
            $message += 0;
            state $prev = 0;
            if ($message != $prev) {
                mekker "n = $message";
                $prev = $message;
            }
        },
	"revspace/button/nomz" => sub {
		my ($topic, $message) = @_;
		mekker "NOMZ!";
		flipdot "<\@\@ N O M Z";
		$off = time() + 27;
	},
	"revspace/button/doorbell" => sub {
		my ($topic, $message) = @_;
		mekker "deurbel";
		flipdot "deurbel \@\@>\n\n deurbel";
		$off = time() + 25;
	},
	"revspace/lichtgordijn" => sub {
		my ($topic, $message) = @_;
		if ($message eq 'IDLE') {
			if ($lichtgordijn_start) {
				my $delta = time() - $lichtgordijn_start;
				open my $fh, ">>/home/bar/saysomething/freenode_revspace";
				printf $fh "Lichtgordijn %.1fs\n", $delta;
			}
			$lichtgordijn_start = undef;
		} else {
			$lichtgordijn_start = time;
		}
	},
);

while (1) {
    $mqtt->tick(.1);
    if ($off and time() > $off) {
        flipdot "";
        undef $off;
    }
}
