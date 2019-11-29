#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;

use Time::HiRes qw(sleep time);
use LWP::Simple ();
use Net::MQTT::Simple;
use Getopt::Long qw(GetOptions);
use List::Util qw(min);
use FindBin qw($RealBin);
use URI::Escape qw(uri_escape);
chdir $RealBin;

my $mqtt = Net::MQTT::Simple->new("mosquitto.space.revspace.nl");
my @topics = (
    "revspace/state",
    "revspace/button/#",
    "revspace/bank/#",
    "revspace/doorduino",
);

my $player = "be:e0:e6:04:46:38";
my $url_host = "http://squeezebox.space.revspace.nl:9000";
my $url_prefix = "$url_host/Classic/status_header.html?player=$player";
my $url_shuffle = "$url_host/Classic/plugins/RandomPlay/mix.html?player=$player&type=track&addOnly=0";
my $url_playlist = "$url_host/status.m3u?player=$player";


sub squeeze {
    my $i = 0;
    my $args = join "&", map { "p" . $i++ . "=" . uri_escape($_) } @_;
    my $url = "$url_prefix&$args";
    warn $url;
    LWP::Simple::get($url);
}

my %players = (
    #mp3 => ["mpv", "--volume=58", "--" ],
    mp3 => ["lame_mp3_wrapper" ],
    wav => ["mpv", "--volume=58", "--" ],
);
my $squeeze_volume = 30;

sub set_squeeze_volume {
    my ($volume) = @_;
    squeeze qw/mixer volume/ => $volume;
}

sub play_sounds {
    my ($path) = @_;

    ($path) = $path =~ m[^([\x20-\x7e]+)$] or do {
        warn "Ignoring non-ascii path.\n";
        return;
    };
    if (grep { $_ eq "." or $_ eq ".." } split m[/], $path) {
        warn "Ignoring path with relative element.\n";
        return;
    }

    my $extensions = join ",", keys %players;
    my $glob = "sounds/$path/*.{$extensions}";
    print "Looking for sounds in $glob... ";
    my @files = glob $glob or do {
        print "none found.\n";
        return;
    };
    print scalar(@files), " found.\n";

    my $file = $files[rand @files];
    
    #my $player = $players{ (split /\./, $file)[-1] } or return;
    my $player = $players{ (split /\./, $file)[-1] } or return;
    print "Playing $file using $player->[0]...\n";

    my $old_squeeze_volume = `perl squeeze-volume.pl`;
    squeeze qw/mixer volume/ => $squeeze_volume if $old_squeeze_volume > $squeeze_volume;
    system @$player, $file;
    squeeze qw/mixer volume/ => $old_squeeze_volume if $old_squeeze_volume > $squeeze_volume;
}

sub handle_mqtt {
    my ($topic, $message, $retain) = @_;
    print "Received $topic ($message)\n";
    if ($retain) {
        print "...but ignoring it because it's a retained message.\n";
        return;
    }

    play_sounds("$topic/$message") if length $message;
    play_sounds($topic);

    sleep 1;
}

$mqtt->run(
    "revspace/button/skip" => sub {
        my @playlist = LWP::Simple::get($url_playlist) =~ /(#EXTURL:.*)/g;

        my %unique;
        $unique{$_}++ for @playlist;

        if (keys(%unique) < 5) {
            LWP::Simple::get($url_shuffle);
        } else {
            squeeze qw/playlist jump/ => "+1";
        }
    },
    map { $_ => \&handle_mqtt } @topics,
);
