#!/usr/bin/perl -w

use strict;
use Net::MQTT::Simple;
use POSIX qw(strftime);

sub writelog {
    use autodie;

    open my $fh, ">>", "$ENV{HOME}/gdpr-consent.log";
    chmod 0600, $fh;
    print $fh strftime ("%Y-%m-%d_%H:%M:%S ", localtime), @_, "\n";
    close $fh;
}

sub opt_in {
    my ($name) = @_;
    use autodie;

    open my $fh, ">>", "$ENV{HOME}/gdpr-consent.list";
    chmod 0600, $fh;
    print $fh $name, "\n";
    close $fh;
}

sub opt_out {
    my ($name) = @_;
    use autodie;

    open my $old, "<", "$ENV{HOME}/gdpr-consent.list";
    open my $new, ">", "$ENV{HOME}/$$.tmp";
    chmod 0600, $new;
    while (defined(my $line = readline $old)) {
        print $new $line unless $line =~ /^\s*\Q$name\E\s*$/i;
    }
    close $old;
    close $new;
    rename "$ENV{HOME}/$$.tmp", "$ENV{HOME}/gdpr-consent.list";
}

sub has_opt_in {
    my ($name) = @_;
    use autodie;

    open my $fh, "<", "$ENV{HOME}/gdpr-consent.list";
    while (defined (my $line = readline $fh)) {
        return 1 if $line =~ /^\s*\Q$name\E\s*$/i;
    }
    return 0;
}

my $mqtt = Net::MQTT::Simple->new("127.0.0.1");

my $space_state = 0;
my $state_changed;
my $counter_reset = time;
my $reset_after = 10 * 60;
my $openings = 0;
my %ppl;
my $sent_since = 0;

my $opt_in_door = 'opt-in';
my $opt_out_door = 'opt-out';

$mqtt->subscribe(
    "revspace/state" => sub {
        my ($topic, $message) = @_;
        $space_state = $message eq 'open';
        $state_changed = time;
    },
    "revspace-local/doorduino/+/unlocked" => sub {
        my ($topic, $message) = @_;
        my $door = (split m[/], $topic)[2];
        my $naam = $message;

        if ($door eq $opt_in_door) {
            writelog "$message $door";
            opt_in $message;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        } elsif ($door eq $opt_out_door) {
            writelog "$message $door";
            opt_out $message;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        }

        # counterstuff
        if (
            !$space_state
            and defined $state_changed
            and $state_changed <= time() - $reset_after
        ) {
            %ppl = ();
            $openings = 0;
            $state_changed = time;
            $counter_reset = time;

            $mqtt->retain("revspace/doorduino/count-since" => $counter_reset);
            $sent_since = 1;
        }

        my $by = '';
        if ($naam ne '[X]') {
            my $temp_id = exists $ppl{$naam}
            ? $ppl{$naam}
            : ($ppl{$naam} = (keys %ppl) + 1);
             # rest wel laten staan, doet ook unique counts
#            $by = " by #$temp_id";
        }

        my $time = strftime "%Y-%m-%d %H:%M:%S", localtime;

        $by = has_opt_in($naam) ? " by $naam" : "";

        if ($door eq $opt_out_door and $by =~ / by /) {
            print STDERR "Opt-out failed; aborting daemon.\n";
            exit 99;  # RestartPreventExitStatus=99 in systemd unit
        }

        my $m = "$door unlocked$by";

        $mqtt->publish("revspace/doorduino" => $m);
#        $mqtt->publish("revspace/flipdot" => "$door\n unlocked\n $by");
        $mqtt->retain("revspace/doorduino/last" => "$time ($m)");
        $mqtt->retain("revspace/doorduino/unique" => 0 + (keys %ppl));
        $mqtt->retain("revspace/doorduino/count" => ++$openings);

        $mqtt->retain("revspace/doorduino/count-since" => $counter_reset) if not $sent_since;
        $sent_since = 1;
    },
);

while (1) {
    $mqtt->tick(.1);
}
