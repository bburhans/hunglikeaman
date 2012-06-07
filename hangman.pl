#!/usr/bin/env perl

## hangman.pl
## Currently:
## - single-connection (TODO: v5)
## - 512-byte length is unchecked and unenforced (TODO: v3)
## - Unicode (UTF-8) support is not yet implemented (TODO: v5)
## - nick collisions are unhandled (TODO: v3)
## - no support for multi-join, multi-message, etc. (TODO: v5 detect this from the 005 string and enable accordingly)
## - no SSL (TODO: v5)
## - no SASL (TODO: v4)
## - stateful nick change (or part/quit and rejoin with another nick) tracking (TODO: v4)
## - admin functions in "me" context (TODO: ???)
## - whitelist of preferred captains (TODO: v2)
## - no AFK detection or resolution (TODO: v3)
## - nothing is logged (TODO: v3 add raw logging with timestamps)
## - everything's hard-coded (TODO: v3 use a configuration file for the tick, mychannel, mykey, host, port, pass, mynick, myuser, mygecos, keepalive, burstable, myquit, admin credentials...)

use strict;
use warnings;

use IO::Socket::INET qw(CRLF);
use IO::Select;

## Connection details
my $host = "irc.example.com";
my $port = 6667;
my $mypass = "";
my $mynick = "hunglikeaman";
my $myuser = "hangman";
my $mygecos = "boycotting nooses since 2012";
my $myquit = "Leaving";
my $mychannel = "#channel";
my $mykey = "";
my $botnick = "rbot";

## Network throttling and keepalive constants
my $tick = 0.4; ## how long to wait for input from the socket and then perform periodic subroutines
my $keepalive = 30; ## if we neither send nor receive data in this many seconds, send a PING to prevent dumb routers from closing the stale connection
my $burstable = 4; ## how many messages can be sent at once
my $throttle = 2; ## seconds between messages (after bursting) to prevent flooding

my @words;
open(WORDS, '< /usr/share/dict/american-english-large') or die "couldn't open dictionary: $!\n";
while(<WORDS>)
{
  chomp;
  push(@words, $_);
}
close(WORDS);

my $sock = IO::Socket::INET->new("$host:$port");
my $in = IO::Select->new();
$in->add($sock);
if ($^O eq "linux")
{
  $in->add(\*STDIN); ## not portable; the Windows select works only on sockets
}

my @q;
my $unbursted = 0;
my $lastreadwrite = 0;
my $bursted = 0;

sub dq
{
  my $time = time();

  if ($time - $unbursted >= $throttle && $bursted > 0)
  {
    --$bursted;
    $unbursted = $time;
  }

  while (scalar(@q) && $bursted < $burstable)
  {
    my $msg = shift(@q);
    syswrite(STDOUT, $msg . CRLF, 512);
    syswrite($sock, $msg . CRLF, 512);
    $lastreadwrite = $time;
    ++$bursted;
  }
}

sub do_raw
{
  my $msg = shift;
  my $priority = shift;
  push(@q, $msg);
  dq();
}

sub do_register
{
  if (defined($mypass) && length($mypass))
  {
    do_raw("PASS :$mypass"); ## the colon might cause problems with some (broken) IRCDs
  }
  do_raw("NICK $mynick");
  do_raw("USER $myuser * * :$mygecos");
}

sub do_join
{
  my $channel = shift;
  my $key = shift;
  my $join = "JOIN $channel";
  if (defined($key) && length($key))
  {
    $join .= " $key";
  }
  do_raw($join);
}

sub do_privmsg
{
  my $target = shift;
  my $msg = shift;
  do_raw("PRIVMSG $target :$msg"); 
}

sub do_notice
{
  my $target = shift;
  my $msg = shift;
  do_raw("NOTICE $target :$msg");
}

sub do_autojoin
{
  do_join($mychannel, $mykey);
}

sub do_quit
{
  my $msg = shift;
  do_raw("QUIT :$msg");
}

sub trap
{
  do_quit($myquit);
  exit 0;
}

$SIG{'INT'} = 'trap';

sub is_authed
{
  my ($nick, $user, $host) = (shift || "", shift || "", shift || "");
  ## empty conditions should mean "anything goes"
  if
  (
    ($nick eq "adminnick" && $user eq "ident" && $host eq "authed.host.name")
  )
  {
    return 1;
  }
  else
  {
    return 0;
  }
}

my $state = 0;

sub reset_state
{
  $state = 0;
}

sub upkeep
{
}

sub build_list
{
  my @list = @_;
  my $last = "";
  
  if (scalar(@list) > 1)
  {
    $last = " and " . splice(@list, -1);
  }

  my $members = join(", ", @list) || "";

  if (scalar(@list) > 1)
  {
    $members = $members . ",";
  }

  return $members . $last;
}

sub choose
{
  my $int = shift;
  return int(rand($int // 2));
}

sub process_nick
{
  ## TODO
}

sub process_quit
{
  ## TODO
}

sub process_part
{
  ## TODO
}

sub process_join
{
  ## TODO
}

sub get_correct
{
  my $pattern = shift;
  my @chars = split(//, lc($pattern));
  my @letters;
  foreach (@chars)
  {
    push(@letters, $_) if ($_ ne '_');
  }
  return @letters;
}

sub get_incorrect
{
  my $string = shift;
  return split(/ /, lc($string));
}

sub guess
{
  my $pattern = shift;
  my $wrong = shift;

  my @guessed = get_correct($pattern);
  push(@guessed, get_incorrect($wrong));
  my @alphabet = ('a' .. 'z');
  my @unguessed;
  foreach (@alphabet)
  {
    my $letter = $_;
    my $no = 0;
    foreach (@guessed)
    {
      if ($letter eq $_)
      {
        $no = 1;
      }
    }
    if (!$no)
    {
      push(@unguessed, $letter);
    }
  }
  my $re = '[' . join('',@unguessed) . ']';

  my @chars = split(//, $pattern);
  foreach (@chars)
  {
    if ($_ eq '_')
    {
      $_ = $re;
    }
    else
    {
      $_ = quotemeta($_);
    }
  }
  $re = '^' . join('', @chars) . '$';
  $re = qr/$re/i;

  my @results = grep {$_ =~ $re} @words;
  if (scalar(@results) == 1)
  {
    do_privmsg($mychannel, $results[0]);
  }
  elsif (scalar(@results > 1))
  {
    my @freq = split(//, "eariotnslcudpmhgbfywkvxzjq"); ## ordered by frequency according to Oxford's English dictionary
    my @candidates = grep {my $f = $_; grep {$_ eq $f} @unguessed;} @freq;
    @candidates = grep {my $f = $_; grep {$_ =~ /$f/i} @results;} @candidates;
    do_privmsg($mychannel, $candidates[0]);
  }
}

my @faces = ('\(^o^)/', ' (^_^) ', ' (o_~) ', ' (-_-) ', ' (>_<) ', ' (;_;) ');
foreach (@faces)
{
  $_ = quotemeta($_);
}
my $re_face = '(?:' . join('|', @faces) . ')';
my $re_s = qr/^.*? has started a hangman -- join the fun!$/;
my $re_w = qr/^(?:[^:]+: )?(.*) $re_face((?: [A-Z])*)$/;
my $re_e = qr/^(?:you(?:'ve killed the poor guy :\(| nailed it!) go|oh well, the answer would've been)/;

sub parse_command
{
  my ($nick, $msg, $context) = (shift, shift, shift);
  my ($command, $args) = split(/\s+/, $msg, 2);

  if ($nick eq $botnick && $context eq "mychannel")
  {
    if ($msg =~ $re_s)
    {
      $state = 1;
    }
    elsif ($state == 1)
    {
      if ($msg =~ $re_w)
      {
        guess($1, $2)
      }
      elsif ($msg =~ $re_e)
      {
        $state = 0;
        do_privmsg($mychannel, "$botnick: hangman");
      }
    }
  }
}

sub process_privmsg
{
  my ($nick, $user, $host, $target, $msg) = (shift, shift, shift, shift, shift);
  my $context;
  if ($target =~ /^[#&]/)
  {
    if ($target eq $mychannel)
    {
      $context = "mychannel";
      parse_command($nick, $msg, $context);
    }
    else
    {
      $context = "channel";
    }
  }
  elsif ($target eq $mynick)
  {
    $context = "me";
    if (is_authed($nick, $user, $host))
    {
      if (substr($msg, 0, 1) eq "!")
      {
        $msg = substr($msg, 1);
      }
      parse_command($nick, $msg, $context);
    }
  }
  else
  {
    $context = "unknown";
  }
}

if ($sock->connected())
{
  do_register();
}
else
{
  die("Not connected!");
}

my $leftovers = "";
my $myserver = "";

sub process
{
  my $buf = $leftovers . shift;
  my $delimiter = CRLF;
  my @lines = split(/\Q$delimiter\E/, $buf, -1); ## negative limit means include empty trailing fields...
  $leftovers = pop(@lines);                      ##  ... which we rely on here in case of empty "leftovers"

  foreach (@lines)
  {
    syswrite(STDOUT, $_ . "\n");

    if (!length($myserver) && /^:(\S+)\s/)
    {
      $myserver = $1; ## very fragile; assumes the first "word" on a connection will be the colon-prefixed server name
    }

    if (/^:\Q$myserver\E 376 \Q$mynick\E/) ## End of MOTD
    {
      do_autojoin();
    }
    elsif (/^PING :(.*)$/)
    {
      do_raw("PONG :$1");
    }
    elsif (/^:([^!]+)!([^@]+)\@(\S+) PRIVMSG (\S+) :(.*)$/)
    {
      process_privmsg($1, $2, $3, $4, $5);
    }
  }
}

while (1)
{
  my @ready = $in->can_read($tick);
  foreach my $handle (@ready)
  {
    my $buf;
    if ($handle == $sock)
    {
      if (sysread($handle, $buf, 512) > 0)
      {
        my $lastreadwrite = time();
        process($buf);
      }
      else
      {
        syswrite STDERR, "EOF\n";
        $in->remove($handle);
        close($handle);
        exit 0;
      }
    }
    elsif ($handle == \*STDIN)
    {
      if (sysread($handle, $buf, 512) > 0)
      {
        syswrite STDERR, $buf;
        syswrite $sock, $buf;
      }
    }
    else
    {
      die "We select()ed a filehandle we don't know about. Abort!\n";
    }
  }

  my $time = time();
  
  upkeep();
  dq();

  if ($time - $lastreadwrite >= $keepalive && scalar(@q) == 0)
  {
    do_raw("PING :keepalive");
  }
  dq();
}

