use strict;

use POSIX qw(strftime);
use Irssi qw(command_bind timeout_add server_find_tag channel_find);

use Net::MQTT::Simple "mosquitto.space.revspace.nl";

my $space_state = 0;
our $state_changed;
*state_changed = \$::state_changed;
our $counter_reset;
*counter_reset = \$::counter_reset;
my $reset_after = 10 * 60;
my $openings = 0;
my %ppl;

sub read_file ($) { local (@ARGV) = shift; <> }

sub revspace_topic_hack {
    my ($server, $chan, $channame, $line) = @_;
    $line =~ /^RevSpace (dicht|open)$/ or return;
    my $status = $1;
    $space_state = $status eq 'open';
    $state_changed = time;
    my $topic = $chan->{topic};
    my ($oldstatus, $rest) = split /\s*%\s*/, $topic, 2;
    $rest &&= " % $rest";
    $server->command("/topic #$channame RevSpace is \U$status\E$rest");
    return 1;
}

my %queue;
my $silence = 0;

my $timer = timeout_add(500, sub {
    eval {
        opendir my $dh, "saysomething" or return;
        my @entries = grep -f "saysomething/$_", readdir $dh;
        if (@entries) {
           $silence = 0;
            for my $fn (@entries) {
                my @lines = read_file("saysomething/$fn")
                    or next;
                unlink "saysomething/$fn" or warn "Couldn't unlink $fn: $!";
                chomp @lines;
                s/\r//g for @lines;
                s/^\[revdoor\] // for @lines;
                push @{ $queue{$fn} }, @lines;
                for (@lines) {
                    if (/^(\S+) unlocked by (\S+)/) {
                        my $naam = $2;

                        if (!$space_state
                        and defined $state_changed
                        and $state_changed <= time() - $reset_after) {
                            %ppl = ();
                            $openings = 0;
                            $state_changed = time;
                            $counter_reset = time;
                        }

                        my $by = '';
                        if ($naam ne '[X]') {
                            my $temp_id = exists $ppl{$naam}
                                ? $ppl{$naam}
                                : ($ppl{$naam} = (keys %ppl) + 1);
                            $by = " by #$temp_id";
                        }

                        my $time = strftime "%Y-%m-%d %H:%M:%S", localtime;
#                        publish "revspace/doorduino" => "$1 unlocked$by ($time)";
#                        retain "revspace/doorduino/unique" => 0 + (keys %ppl);
#                        retain "revspace/doorduino/count" => ++$openings;
                    }
                }
            }
        } else {
            return if not keys %queue;
            return if $silence++ < 15;

            for my $fn (keys %queue) {
                my ($server, $channame) = split /_/, $fn;
                my $server = server_find_tag($server) or do {
                    Irssi::print("No such server tag '$server'");
                    next;
                };
                my $chan = $server->channel_find("#$channame") or do {
                    Irssi::print("No such channel '#$channame'");
                    next;
                };
                my @queue = @{ $queue{$fn} };
                if ($fn eq "liberachat_revspace") {
                    revspace_topic_hack($server, $chan, $channame, $_)
                        for @queue;
                }
                $server->command(
                    "/notice #$channame " . join " % ", @{ $queue{$fn} }
                );
            }
            $silence = 0;
            %queue = ();
        };
    };
    Irssi::print($@) if $@;  # Something makes it crash; I wanna know what.
}, "dummy");
Irssi::command_bind(saynothing => sub { Irssi::timeout_remove($timer) });

