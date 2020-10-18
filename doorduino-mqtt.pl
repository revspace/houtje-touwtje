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

# Basically stolen from pwgen's pw_phonemes.c, dropping the passwordlike stuff
my %el = qw(a 2 ae 6 ah 6 ai 6 b 1 c 1 ch 5 d 1 e 2 ee 6 ei 6 f 1 g 1 gh 13 h 1
i 2 ie 6 j 1 k 1 l 1 m 1 n 1 ng 13 o 2 oh 6 oo 6 p 1 ph 5 qu 5 r 1 s 1 sh 5 t 1
th 5 u 2 v 1 w 1 x 1 y 1 z 1 ij 6 au 6 eu 6 ui 6 oe 6 aa 6 uu 6);

sub random_nick {
    my ($size) = @_;

    my $pw = "";
    my $prev = 0;
    my $w = int rand 2 ? 2 : 1;
    {
        my $str = (keys %el)[rand keys %el];
        my $el = $el{$str};
        redo if not $el & $w;
        redo if $el & 8 and $pw eq "";
        redo if $prev & 2 and $el & 2 and $el & 4;
        redo if length("$pw$str") > $size;

        $pw .= $str;
        if (length($pw) < $size) {
            $w = $w == 1 ? 2 : ($prev & 2 or $el & 4 or rand(10) > 5) ? 1 : 2;
            $prev = $el;
            redo;
        }
    }
    return $pw;
}

my $mqtt = Net::MQTT::Simple->new("127.0.0.1");

my $space_state = 0;
my $state_changed;
my $counter_reset = time;
my $reset_after = 10 * 60;
my $openings = 0;
my %ppl;
my %pseudonyms;
my %checked_in;
my $sent_since = 0;

my $opt_in_door = 'opt-in';
my $opt_out_door = 'opt-out';
my $check_out_door = 'doei';

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

        my $old_n = keys %checked_in;

        # counterstuff
        if (
            !$space_state
            and defined $state_changed
            and $state_changed <= time() - $reset_after
        ) {
            %ppl = ();
            %pseudonyms = ();
            %checked_in = ();
            $openings = 0;
            $state_changed = time;
            $counter_reset = time;

            $mqtt->retain("revspace/doorduino/count-since" => $counter_reset);

            # voor IRC-melding meteen doen want men snapt het resetmoment anders niet
            $mqtt->retain("revspace/doorduino/checked-in" => 0);
            $mqtt->retain("revspace-local/doorduino/checked-in" => "");
            $mqtt->retain("revspace-local/doorduino/checked-in/unixtime" => "");
            $sent_since = 1;
        }

        # fake doors
        if ($door eq $opt_in_door) {
            writelog "$naam $door";
            opt_in $naam;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        } elsif ($door eq $opt_out_door) {
            delete $pseudonyms{$naam} if has_opt_in($naam);

            writelog "$naam $door";
            opt_out $naam;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        } elsif ($door eq $check_out_door) {
            delete $checked_in{$naam};
        } elsif ($naam !~ /^\$/) {
            $checked_in{$naam} ||= time;
        }

        # old counter (merge with above?)
        my $by = '';
        if ($naam ne '[X]') {
            my $temp_id = exists $ppl{$naam}
            ? $ppl{$naam}
            : ($ppl{$naam} = (keys %ppl) + 1);
             # rest wel laten staan, doet ook unique counts
#            $by = " by #$temp_id";
        }

        # notifications
        my $pseudo = $pseudonyms{$naam} ||= random_nick(5 + int rand 4);

        my $time = strftime "%Y-%m-%d %H:%M:%S", localtime;

        $by = has_opt_in($naam) ? " by $naam" : " by /tmp/$pseudo";

        if ($door eq $opt_out_door and $by =~ m[ by (?!/tmp/)]) {
            print STDERR "Opt-out failed; aborting daemon.\n";
            exit 99;  # RestartPreventExitStatus=99 in systemd unit
        }

        my $m = "$door unlocked$by";

        $mqtt->publish("revspace/doorduino" => $m);
        my $n = 0 + keys %checked_in;
#        my $regel2 = ($n == 9 ? "maak plaats" : $n == 10 ? "ga naar huis" : "      ");
        my $regel2 = ($n >= 5 ? "ga naar huis" : "      ");
        $mqtt->publish("revspace/flipdot" => "n = " . (0 + keys %checked_in) . "\n $regel2");
        $mqtt->retain("revspace/doorduino/last" => "$time ($m)");
        $mqtt->retain("revspace/doorduino/unique" => 0 + (keys %ppl));
        $mqtt->retain("revspace/doorduino/checked-in" => $n);
        $mqtt->retain("revspace-local/doorduino/checked-in" => join(" ", sort keys %checked_in));
        $mqtt->retain("revspace-local/doorduino/checked-in/unixtime" => join(" ", %checked_in{sort keys %checked_in}));
        $mqtt->retain("revspace/doorduino/count" => ++$openings);

        $mqtt->retain("revspace/doorduino/count-since" => $counter_reset) if not $sent_since;
        $sent_since = 1;
    },
);

while (1) {
    $mqtt->tick(.1);
}
