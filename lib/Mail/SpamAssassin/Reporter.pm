# Mail::SpamAssassin::Reporter - report a message as spam

# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::Reporter;

# Make the main dbg() accessible in our package w/o an extra function
*dbg=\&Mail::SpamAssassin::dbg;

use strict;
use warnings;
use bytes;
use Carp;
use POSIX ":sys_wait_h";
use constant HAS_NET_DNS => eval { require Net::DNS; };
use constant HAS_NET_SMTP => eval { require Net::SMTP; };

use vars qw{
  @ISA $VERSION
};

@ISA = qw();
$VERSION = 'bogus';	# avoid CPAN.pm picking up razor ver

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my ($main, $msg, $options) = @_;

  my $self = {
    'main'		=> $main,
    'msg'		=> $msg,
    'options'		=> $options,
    'conf'		=> $main->{conf},
  };

  bless ($self, $class);
  $self;
}

###########################################################################

sub report {
  my ($self) = @_;
  $self->{report_return} = 1;
  $self->{report_available} = 0;

  my $text = $self->{main}->remove_spamassassin_markup ($self->{msg});

  if (!$self->{options}->{dont_report_to_dcc} && $self->is_dcc_available()) {
    if ($self->dcc_report($text)) {
      $self->{report_available} = 1;
      dbg("reporter: spam reported to DCC");
      $self->{report_return} = 0;
    }
    else {
      dbg("reporter: could not report spam to DCC");
    }
  }
  if (!$self->{options}->{dont_report_to_pyzor} && $self->is_pyzor_available()) {
    if ($self->pyzor_report($text)) {
      $self->{report_available} = 1;
      dbg("reporter: spam reported to Pyzor");
      $self->{report_return} = 0;
    }
    else {
      dbg("reporter: could not report spam to Pyzor");
    }
  }
  if (!$self->{options}->{dont_report_to_spamcop} && $self->is_spamcop_available()) {
    if ($self->spamcop_report($text)) {
      $self->{report_available} = 1;
      dbg("reporter: spam reported to SpamCop");
      $self->{report_return} = 0;
    }
    else {
      dbg("reporter: could not report spam to SpamCop.");
    }
  }

  $self->{main}->call_plugins ("plugin_report", { report => $self, text => \$text, msg => $self->{msg} });

  $self->delete_fulltext_tmpfile();

  if ($self->{report_available} == 0) {
    warn "reporter: no network reporting methods available, so couldn't report\n";
  }

  return $self->{report_return};
}

###########################################################################

sub revoke {
  my ($self) = @_;
  $self->{revoke_return} = 0;
  $self->{revoke_available} = 0;

  my $text = $self->{main}->remove_spamassassin_markup($self->{msg});

  $self->{main}->call_plugins ("plugin_revoke", { revoke => $self, text => \$text, msg => $self->{msg} });

  return $self->{revoke_return};
}

###########################################################################
# non-public methods.

# Close an fh piped to a process, possibly exiting if the process returned nonzero.
# thanks to nix /at/ esperi.demon.co.uk for this.
sub close_pipe_fh {
  my ($self, $fh) = @_;

  return if close ($fh);

  my $exitstatus = $?;
  dbg("reporter: raw exit code: $exitstatus");

  if (WIFEXITED ($exitstatus) && (WEXITSTATUS ($exitstatus))) {
    die "reporter: exited with non-zero exit code " . WEXITSTATUS ($exitstatus) . "\n";
  }

  if (WIFSIGNALED ($exitstatus)) {
    die "reporter: exited due to signal " . WTERMSIG ($exitstatus) . "\n";
  }
}

sub dcc_report {
  my ($self, $fulltext) = @_;
  my $timeout=$self->{conf}->{dcc_timeout};

  $self->enter_helper_run_mode();

  # use a temp file here -- open2() is unreliable, buffering-wise,
  # under spamd. :(
  my $tmpf = $self->create_fulltext_tmpfile(\$fulltext);
  my $oldalarm = 0;

  eval {
    local $SIG{ALRM} = sub { die "__alarm__\n" };
    local $SIG{PIPE} = sub { die "__brokenpipe__\n" };

    $oldalarm = alarm $timeout;

    # Note: not really tainted, these both come from system conf file.
    my $path = Mail::SpamAssassin::Util::untaint_file_path ($self->{conf}->{dcc_path});

    my $opts = '';
    if ( $self->{conf}->{dcc_options} =~ /^([^\;\'\"\0]+)$/ ) {
      $opts = $1;
    }

    my $pid = Mail::SpamAssassin::Util::helper_app_pipe_open(*DCC,
                    $tmpf, 1, $path, "-t", "many", split(' ', $opts));
    $pid or die "$!\n";
    my @ignored = <DCC>;
    $self->close_pipe_fh (\*DCC);

    waitpid ($pid, 0);
    alarm $oldalarm;
  };

  my $err = $@;

  # do not call alarm $oldalarm here, that *may* have already taken place
  $self->leave_helper_run_mode();
 
  if ($err) {
    alarm $oldalarm;  # reinstate the one we missed
    if ($err =~ /^__alarm__$/) {
      dbg("reporter: DCC report timed out after $timeout seconds");
    } elsif ($err =~ /^__brokenpipe__$/) {
      dbg("reporter: DCC report failed: broken pipe");
    } else {
      warn("reporter: DCC report failed: $err\n");
    }
    return 0;
  }

  return 1;
}

sub pyzor_report {
  my ($self, $fulltext) = @_;
  my $timeout=$self->{conf}->{pyzor_timeout};

  $self->enter_helper_run_mode();

  # use a temp file here -- open2() is unreliable, buffering-wise,
  # under spamd. :(
  my $tmpf = $self->create_fulltext_tmpfile(\$fulltext);
  my $oldalarm = 0;

  eval {
    local $SIG{ALRM} = sub { die "__alarm__\n" };
    local $SIG{PIPE} = sub { die "__brokenpipe__\n" };

    $oldalarm = alarm $timeout;

    # Note: not really tainted, this comes from system conf file.
    my $path = Mail::SpamAssassin::Util::untaint_file_path ($self->{conf}->{pyzor_path});

    my $opts = '';
    if ( $self->{conf}->{pyzor_options} =~ /^([^\;\'\"\0]+)$/ ) {
      $opts = $1;
    }

    #my $pid = open(PYZOR, join(' ', $path, $opts, "report", "< '$tmpf'", ">/dev/null 2>&1", '|')) || die "$!\n";
    my $pid = Mail::SpamAssassin::Util::helper_app_pipe_open(*PYZOR,
                    $tmpf, 1, $path, split(' ', $opts), "report");
    $pid or die "$!\n";
    my @ignored = <PYZOR>;
    $self->close_pipe_fh (\*PYZOR);

    alarm $oldalarm;
    waitpid ($pid, 0);
  };

  my $err = $@;

  # do not call alarm $oldalarm here, that *may* have already taken place
  $self->leave_helper_run_mode();

  if ($err) {
    alarm $oldalarm;
    if ($err =~ /^__alarm__$/) {
      dbg("reporter: pyzor report timed out after $timeout seconds");
    } elsif ($err /^__brokenpipe__$/) {
      dbg("reporter: pyzor report failed: broken pipe");
    } else {
      warn("reporter: pyzor report failed: $err\n");
    }
    return 0;
  }

  return 1;
}

sub smtp_dbg {
  my ($command, $smtp) = @_;

  dbg("reporter: SpamCop sent $command");
  my $code = $smtp->code();
  my $message = $smtp->message();
  my $debug;
  $debug .= $code if $code;
  $debug .= ($code ? " " : "") . $message if $message;
  chomp $debug;
  dbg("reporter: SpamCop received $debug");
  return 1;
}

sub spamcop_report {
  my ($self, $original) = @_;

  # check date
  my $header = $original;
  $header =~ s/\r?\n\r?\n.*//s;
  my $date = Mail::SpamAssassin::Util::receive_date($header);
  if ($date && $date < time - 3*86400) {
    warn("reporter: SpamCop message older than 3 days, not reporting\n");
    return 0;
  }

  # message variables
  my $boundary = "----------=_" . sprintf("%08X.%08X",time,int(rand(2**32)));
  while ($original =~ /^\Q${boundary}\E$/m) {
    $boundary .= "/".sprintf("%08X",int(rand(2**32)));
  }
  my $description = "spam report via " . Mail::SpamAssassin::Version();
  my $trusted = $self->{msg}->{metadata}->{relays_trusted_str};
  my $untrusted = $self->{msg}->{metadata}->{relays_untrusted_str};
  my $user = $self->{main}->{'username'} || 'unknown';
  my $host = Mail::SpamAssassin::Util::fq_hostname() || 'unknown';
  my $from = $self->{conf}->{spamcop_from_address} || "$user\@$host";

  # message data
  my %head = (
	      'To' => $self->{conf}->{spamcop_to_address},
	      'From' => $from,
	      'Subject' => 'report spam',
	      'Date' => Mail::SpamAssassin::Util::time_to_rfc822_date(),
	      'Message-Id' =>
		sprintf("<%08X.%08X@%s>",time,int(rand(2**32)),$host),
	      'MIME-Version' => '1.0',
	      'Content-Type' => "multipart/mixed; boundary=\"$boundary\"",
	      );

  # truncate message
  if (length($original) > 64*1024) {
    substr($original,(64*1024)) = "\n[truncated by SpamAssassin]\n";
  }

  my $body = <<"EOM";
This is a multi-part message in MIME format.

--$boundary
Content-Type: message/rfc822; x-spam-type=report
Content-Description: $description
Content-Disposition: attachment
Content-Transfer-Encoding: 8bit
X-Spam-Relays-Trusted: $trusted
X-Spam-Relays-Untrusted: $untrusted

$original
--$boundary--

EOM

  # compose message
  my $message;
  while (my ($k, $v) = each %head) {
    $message .= "$k: $v\n";
  }
  $message .= "\n" . $body;

  # send message
  my $failure;
  my $mx = $head{To};
  my $hello = Mail::SpamAssassin::Util::fq_hostname() || $from;
  $mx =~ s/.*\@//;
  $hello =~ s/.*\@//;
  for my $rr (Net::DNS::mx($mx)) {
    my $exchange = Mail::SpamAssassin::Util::untaint_hostname($rr->exchange);
    next unless $exchange;
    my $smtp;
    if ($smtp = Net::SMTP->new($exchange,
			       Hello => $hello,
			       Port => 587,
			       Timeout => 10))
    {
      if ($smtp->mail($from) && smtp_dbg("FROM $from", $smtp) &&
	  $smtp->recipient($head{To}) && smtp_dbg("TO $head{To}", $smtp) &&
	  $smtp->data($message) && smtp_dbg("DATA", $smtp) &&
	  $smtp->quit() && smtp_dbg("QUIT", $smtp))
      {
	# tell user we succeeded after first attempt if we previously failed
	warn("reporter: SpamCop report to $exchange succeeded\n") if defined $failure;
	return 1;
      }
      my $code = $smtp->code();
      my $text = $smtp->message();
      $failure = "$code $text" if ($code && $text);
    }
    $failure ||= "Net::SMTP error";
    chomp $failure;
    warn("reporter: SpamCop report to $exchange failed: $failure\n");
  }

  return 0;
}

###########################################################################

sub create_fulltext_tmpfile { Mail::SpamAssassin::PerMsgStatus::create_fulltext_tmpfile(@_) }
sub delete_fulltext_tmpfile { Mail::SpamAssassin::PerMsgStatus::delete_fulltext_tmpfile(@_) }

# Use the Dns versions ...  At least something only needs 1 copy of code ...
sub is_dcc_available {
  Mail::SpamAssassin::PerMsgStatus::is_dcc_available(@_);
}
sub is_pyzor_available {
  Mail::SpamAssassin::PerMsgStatus::is_pyzor_available(@_);
}
sub is_spamcop_available {
  my ($self) = @_;
  return (HAS_NET_DNS &&
	  HAS_NET_SMTP &&
	  $self->{conf}{scores}{'RCVD_IN_BL_SPAMCOP_NET'});
}

sub enter_helper_run_mode { Mail::SpamAssassin::PerMsgStatus::enter_helper_run_mode(@_); }
sub leave_helper_run_mode { Mail::SpamAssassin::PerMsgStatus::leave_helper_run_mode(@_); }

1;
