use strict;
use warnings;

# This file tests interactions with locale and threads

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require './loc_tools.pl';
    skip_all("No locales") unless locales_enabled();
    skip_all_without_config('useithreads');
    $| = 1;
    eval { require POSIX; POSIX->import(qw(locale_h  unistd_h)) };
    if ($@) {
	skip_all("could not load the POSIX module"); # running minitest?
    }
}

# reset the locale environment
local @ENV{'LANG', (grep /^LC_/, keys %ENV)};

SKIP: { # perl #127708
last;
    my @locales = grep { $_ !~ / ^ C \b | POSIX /x } find_locales('LC_MESSAGES');
    skip("No valid locale to test with", 1) unless @locales;

    local $ENV{LC_MESSAGES} = $locales[0];

    # We're going to try with all possible error numbers on this platform
    my $error_count = keys(%!) + 1;

    print fresh_perl("
        use threads;
        use strict;
        use warnings;

        my \$errnum = 1;

        my \@threads = map +threads->create(sub {
            sleep 0.1;

            for (1..5_000) {
                \$errnum = (\$errnum + 1) % $error_count;
                \$! = \$errnum;

                # no-op to trigger stringification
                next if \"\$!\" eq \"\";
            }
        }), (0..1);
        \$_->join for splice \@threads;",
    {}
    );

    pass("Didn't segfault");
}

SKIP: {
last;
    my @locales = find_locales( 'LC_NUMERIC' );
    skip("No LC_NUMERIC locales available", 1) unless @locales;

    my $dot = "";
    my $comma = "";
    for (@locales) { # prefer C for the base if available
        use locale;
        setlocale(LC_NUMERIC, $_) or next;
        my $in = 4.2; # avoid any constant folding bugs
        if ((my $s = sprintf("%g", $in)) eq "4.2")  {
            $dot ||= $_;
        } else {
            my $radix = localeconv()->{decimal_point};
            $comma ||= $_ if $radix eq ',';
        }

        last if $dot && $comma;
    }

    # See if multiple threads can simultaneously change the locale, and give
    # the expected radix results.  On systems without a comma radix locale,
    # run this anyway skipping the use of that, to verify that we don't
    # segfault
    fresh_perl_is("
        use threads;
        use strict;
        use warnings;
        use POSIX qw(locale_h);

        my \$result = 1;

        my \@threads = map +threads->create(sub {
            sleep 0.1;
            for (1..5_000) {
                my \$s;
                my \$in = 4.2; # avoid any constant folding bugs

                if ('$comma') {
                    setlocale(&LC_NUMERIC, '$comma');
                    use locale;
                    \$s = sprintf('%g', \$in);
                    return 0 if (\$s ne '4,2');
                }

                setlocale(&LC_NUMERIC, '$dot');
                \$s = sprintf('%g', \$in);
                return 0 if (\$s ne '4.2');
            }

            return 1;

        }), (0..3);
        \$result &= \$_->join for splice \@threads;
        print \$result",
    1, {}, "Verify there were no failures with simultaneous running threads"
    );
}

sub call_strftime { return POSIX::strftime("%c", 0, 0, ,0, 2, 2, 120); }

SKIP: {
    my @locales = find_locales( 'LC_TIME' );
    skip("No LC_TIME locales available", 1) unless @locales;

    my $max = 95;
    my %outputs;

    skip("Failed to set locale to 'C'") unless setlocale(LC_TIME, "C");
    $outputs{C} = call_strftime();

    for (@locales) { # prefer C for the base if available
        use locale;
        next if $_ =~ /@/;
        setlocale(LC_TIME, $_) or next;

        my $this_date = call_strftime();
        next if grep { $_ eq $this_date } values %outputs;
        $outputs{$_} = $this_date;
        last if keys %outputs > $max;
    }

    my $locales = join "\",\"", keys %outputs;
    my $values = join "\",\"", values %outputs;
    $locales = "my \@locales = ( \"$locales\" );";
    $values = "my \@values = ( \"$values\" );";
    #diag join "\n", %outputs;

    # See if multiple threads can simultaneously change the locale, and give
    # the expected radix results.  On systems without a comma radix locale,
    # run this anyway skipping the use of that, to verify that we don't
    # segfault
    fresh_perl_is("
        use threads;
        use strict;
        use warnings;
        use POSIX qw(locale_h);
        use utf8;
        \$|=1;

        sub call_strftime { return POSIX::strftime(\"%c\", 0, 0, ,0, 2, 2, 120); }

        $locales
        $values

        my \$result = 1;

        my \@threads = map +threads->create(sub {

        my \$i = shift;
            sleep .1;
            for (1..5000) {

                setlocale(&LC_TIME, \$locales[\$i]);
                return 0 if (call_strftime() ne \$values[\$i]);

                threads->yield();

                setlocale(&LC_TIME, 'C');
                return 0 if (call_strftime() ne '$outputs{C}');
                sleep .1;

                threads->yield();

                }

            return 1;

            }, \$_), (0..$max);
        \$result &= \$_->join for splice \@threads;
        print \$result",
    1, { args => [ '-CE' ]}, "Verify there were no failures with simultaneous running threads"
    );
}

done_testing();
