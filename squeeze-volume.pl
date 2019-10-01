#!/usr/bin/perl
use strict;
use URI::Escape qw(uri_escape uri_unescape);
use Socket qw(SOCK_STREAM inet_ntoa);
use IO::Socket::INET;
use IO::Select;

my $host = '10.42.66.2';
my $player = 'be:e0:e6:04:46:38';

{
    my $socket;
    sub squeeze {
        my @args = @_;
        $_ = uri_escape($_) for @args;

        $socket && $socket->connected or $socket = IO::Socket::INET->new(
            PeerHost => "$host:9090",
            Type => SOCK_STREAM,
        ) or return;

        $socket->print("@args\n");
        my @reply = split " ", readline $socket;
        $_ = uri_unescape($_) for @reply;
        return @reply;
    }
}

sub group {
    my $firstkey = shift;
    my $returncommon = $firstkey =~ s/^-//;
    my $common;
    my @items;
    while (defined (my $input = shift)) {
        if ($input =~ /:/) {
            my ($key, $value) = split /:/, $input, 2;
            $key =~ s/ /_/g;
            if ($key eq $firstkey) {
                push @items, { $key => $value };
            } elsif (@items) {
                $items[-1]{ $key } = $value;
            } else {
                $common->{ $key } = $value;
            }
        } else {
            push @{ $common->{_} }, $_;
        }
    }
    return $common, @items if $returncommon;
    return @items;
}

sub squeeze_volume {
    my ($status, @plist) = group
        -playlist_index => squeeze $player, qw'status - 1';

    return $status->{mixer_volume} //= 0;
}

print squeeze_volume, "\n";
