#!/usr/bin/perl -w

use strict;
use Net::MQTT::Simple;
use POSIX qw(strftime);
use List::Util qw(max);

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

    return 1 if $name =~ /^\$/;

    open my $fh, "<", "$ENV{HOME}/gdpr-consent.list";
    while (defined (my $line = readline $fh)) {
        return 1 if $line =~ /^\s*\Q$name\E\s*$/i;
    }
    return 0;
}

sub ibutton2name {
    my ($id) = @_;
    $id =~ /^[0-9A-Fa-f]{16}$/ or return undef;

    my $fn = "$ENV{HOME}/ibuttons.acl";
    open my $fh, "<", $fn or warn "$fn: $!";
    while (defined (my $line = readline $fh)) {
        chomp $line;
        $line =~ /\S/ or next;
        $line =~ /^\s*#/ and next;
        my ($line_id, $line_name) = split " ", $line, 2;
        warn "ACL contains secrets!!!" if $line_id =~ /:/;
        return $line_name if lc($line_id) eq lc($id);
    }
    return undef;
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

my $scheduled_reset;
my $counter_reset = time;

# Normaal:
#my $autodoei_after_close = 10 * 60;   # space wordt gesloten
#my $autodoei_after_checkin = 5 * 60;  # iemand komt binnen bij gesloten space

# Zinniger bij max_n = 1:
my $scheduled_autodoei;
my $autodoei_after_close = 5 * 60;   # space wordt gesloten: duidelijke intentie weg te gaan
my $autodoei_after_checkin = 15 * 60;  # iemand komt binnen bij gesloten space, opent mogelijk space niet, want denk dat dat niet nodig is bij max_n = 1.

my $scheduled_pseudoclear;
my $pseudo_ttl_after_close = 30 * 60;  # moet groter dan max(autodoei_after_*) zijn

my $openings = 0;
my %ppl;
my %pseudonyms;
my %checked_in;
my $sent_since = 0;

my $opt_in_door = 'opt-in';
my $opt_out_door = 'opt-out';
my $check_out_door = qr/doei$/;
my %no_check_in_door = (sparkshack => 1, spacefietssleutelkastje => 1);

sub reset_state {
    %ppl = ();
    %pseudonyms = ();
    %checked_in = ();
    $openings = 0;
    $counter_reset = time;
    $scheduled_autodoei = undef;
    $scheduled_pseudoclear = undef;

    $mqtt->retain("revspace/doorduino/count-since" => $counter_reset);

    # voor IRC-melding meteen doen want men snapt het resetmoment anders niet
    $mqtt->retain("revspace/doorduino/checked-in" => 0);
    $mqtt->retain("revspace-local/doorduino/checked-in" => "");
    $mqtt->retain("revspace-local/doorduino/checked-in/unixtime" => "");

    $sent_since = 1;
}

sub autodoei_all {
    for my $name (keys %checked_in) {
        $mqtt->publish("revspace-local/doorduino/autodoei/unlocked", $name);
        sleep .05;
        $mqtt->tick(.1);  # Bovenstaand mqtt-bericht ontvangen en verwerken.
        # Geen idee of dit goed genoeg werkt; zou incomplete berichten kunnen
        # krijgen als er ook andere dingen gebeuren.
    }
    $scheduled_autodoei = undef;
}

sub clear_pseudos {
    if (%checked_in) {
        warn "Dit zou niet moeten";
        return;
    }
    %pseudonyms = ();
    $scheduled_pseudoclear = undef;
}

$mqtt->subscribe(
    "revspace/state" => sub {
        my ($topic, $message) = @_;
        $space_state = $message eq 'open';

        $scheduled_autodoei = (
            $space_state
            ? undef
            : time() + $autodoei_after_close
        );
        $scheduled_pseudoclear = (
            $space_state
            ? undef
            : time() + $pseudo_ttl_after_close
        );
    },
    "revspace-local/doorduino/extradoei/+/unlocked" => sub {
        my ($topic, $message) = @_;

        # ibutton id vertalen naar naam, en bij volgende ronde verwerken
        my $name = ibutton2name($message);

        if (defined $name and $name !~ /^\$/) {
            $mqtt->publish("revspace-local/doorduino/extradoei/unlocked", $name);
            $mqtt->publish($topic =~ s/unlocked/result/r, "ok");
        } else {
            $mqtt->publish($topic =~ s/unlocked/result/r, "bad");
        }
    },
    "revspace-local/doorduino/+/unlocked" => sub {
        my ($topic, $message) = @_;
        my $door = (split m[/], $topic)[2];
        my $naam = $message;
        my $additional = "";

        my $old_n = keys %checked_in;

        # fake doors
        if ($door eq $opt_in_door) {
            writelog "$naam $door";
            return if $naam =~ /^$/;

            opt_in $naam;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        } elsif ($door eq $opt_out_door) {
            writelog "$naam $door";
            return if $naam =~ /^$/;

            delete $pseudonyms{$naam} if has_opt_in($naam);
            opt_out $naam;
            $mqtt->publish("revspace-local/doorduino/$door/unlock", "");
        } elsif ($door =~ $check_out_door) {
            my $checkintime = delete $checked_in{$naam};
            if ($checkintime) {
                my $s = time() - $checkintime;
                my $h = int($s / 3600);
                $s -= $h * 3600;
                my $m = int($s / 60);
                $s -= $m * 60;
                if ($h) {
                    $additional = sprintf " (%dh %dm)", $h, $m;
                } else {
                    $additional = sprintf " (%dm %ds)", $m, $s;
                }
            }
        } elsif ($naam !~ /^\$/ and not exists $no_check_in_door{$door}) {
            $checked_in{$naam} ||= time;

            $scheduled_autodoei = max(
                $scheduled_autodoei // 0,
                time() + $autodoei_after_checkin
            ) if not $space_state;
        }

        # notifications/counters
        my $pseudo = $pseudonyms{$naam} ||= random_nick(5 + int rand 4);

        my $time = strftime "%Y-%m-%d %H:%M:%S", localtime;

        my $by = has_opt_in($naam) ? " by $naam" : " by /tmp/$pseudo";

        if ($door eq $opt_out_door and $by =~ m[ by (?!/tmp/)]) {
            print STDERR "Opt-out failed; aborting daemon.\n";
            exit 99;  # RestartPreventExitStatus=99 in systemd unit
        }

        my $m = "$door unlocked$by$additional";

        $mqtt->publish("revspace/doorduino" => $m);
        my $n = 0 + keys %checked_in;

        my $optin = has_opt_in($naam) ? "__OPT_IN__" : "";
        $mqtt->publish("revspace-local/ledbanner/doorduino" => "#00ffff$door #ff0000unlocked by #00ff00$naam $optin");

#        my $regel2 = ($n == 9 ? "maak plaats" : $n == 10 ? "ga naar huis" : "      ");
        my $regel2 = ($n >= 4 ? "open de ramen" : "      ");
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

reset_state;

while (1) {
    $mqtt->tick(.1);

    autodoei_all  if defined $scheduled_autodoei and time() >= $scheduled_autodoei;
    clear_pseudos if defined $scheduled_pseudoclear and time() >= $scheduled_pseudoclear;
}
