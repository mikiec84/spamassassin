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
use SATest; sa_t_init("relaycountry");

use constant HAS_GEOIP2 => eval { require GeoIP2::Database::Reader; };

use Test::More;

plan skip_all => "GeoIP2::Database::Reader not installed" unless HAS_GEOIP2;
plan tests => 2;

# ---------------------------------------------------------------------------

tstpre ("
loadplugin Mail::SpamAssassin::Plugin::RelayCountry
");

tstprefs ("
        geodb_module GeoIP2
        geoip_search_path data/geodb

        add_header all Relay-Country _RELAYCOUNTRY_
        ");

# Check for country of gmail.com mail server
%patterns = (
        q{ X-Spam-Relay-Country: US },
            );

ok sarun ("-L -t < data/spam/relayUS.eml", \&patterns_run_cb);
ok_all_patterns();