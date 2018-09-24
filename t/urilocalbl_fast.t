#!/usr/bin/perl

BEGIN {
  if (-e 't/test_dir') { # if we are running "t/rule_tests.t", kluge around ...
    chdir 't';
  }

  if (-e 'test_dir') {            # running from test directory, not ..
    unshift(@INC, '../blib/lib');
    unshift(@INC, '../lib');
  }
}

use lib '.'; use lib 't';
use SATest; sa_t_init("urilocalbl");

use constant HAS_COUNTRY_FAST => eval { require IP::Country::Fast; };

use Test::More;

plan skip_all => "No GeoDB module could be loaded" unless HAS_COUNTRY_FAST;
#plan skip_all => "Net tests disabled"          unless conf_bool('run_net_tests');
plan tests => 8;

# ---------------------------------------------------------------------------

tstpre ("
loadplugin Mail::SpamAssassin::Plugin::URILocalBL
");

%patterns = (
  q{ X_URIBL_USA } => 'USA',
  q{ X_URIBL_FINEG } => 'except Finland',
  q{ X_URIBL_NA } => 'north America',
  q{ X_URIBL_EUNEG } => 'except Europe',
  q{ X_URIBL_CIDR1 } => 'our TestIP1',
  q{ X_URIBL_CIDR2 } => 'our TestIP2',
  q{ X_URIBL_CIDR3 } => 'our TestIP3',
);

tstlocalrules ("
  geodb_module Fast

  uri_block_cc X_URIBL_USA us
  describe X_URIBL_USA uri located in USA
  
  uri_block_cc X_URIBL_FINEG !fi
  describe X_URIBL_FINEG uri located anywhere except Finland

  uri_block_cont X_URIBL_NA na
  describe X_URIBL_NA uri located in north America

  uri_block_cont X_URIBL_EUNEG !eu !af
  describe X_URIBL_EUNEG uri located anywhere except Europe/Africa

  uri_block_cidr X_URIBL_CIDR1 8.0.0.0/8 8.8.0.0/16
  describe X_URIBL_CIDR1 uri is our TestIP1

  uri_block_cidr X_URIBL_CIDR2 8.8.8.8
  describe X_URIBL_CIDR2 uri is our TestIP2

  uri_block_cidr X_URIBL_CIDR3 8.8.8.0/24
  describe X_URIBL_CIDR3 uri is our TestIP3
");

ok sarun ("-L -t < data/spam/relayUS.eml", \&patterns_run_cb);
ok_all_patterns();