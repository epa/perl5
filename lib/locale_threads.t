
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
    eval { require POSIX; POSIX->import(qw(errno_h locale_h  unistd_h )) };
    if ($@) {
	skip_all("could not load the POSIX module"); # running minitest?
    }
}

# reset the locale environment
local @ENV{'LANG', (grep /^LC_/, keys %ENV)};

sub C_first ()
{
    $a eq 'C' ? -1 : $b eq 'C' ? 1 : $a cmp $b;
}

my $strftime_args = "'%c', 0, 0, ,12, 18, 11, 87";

my $has_lc_all = 0;
my $dumper_times;
my $max_threads = 100;
my $locales_min = 3;
my $locales_max_so_far = 0;
my %tests;

my @dates;
use Data::Dumper;
$Data::Dumper::Sortkeys=1;
$Data::Dumper::Useqq = 1;

sub add_trials($$;$)
{
    my $category_name = shift;
    my $eval_test = shift;
    my $sub_category = shift;

    my $category_number = eval "&POSIX::$category_name";
    die "$@" if $@;

    my @results;
    my @locales = sort C_first find_locales($category_name);

    while (1) {
        my %seen;
        foreach my $locale (@locales) {
            use locale;
            next unless setlocale($category_number, $locale);

            my $result = ref $eval_test
                        ? &$eval_test
                        : eval $eval_test;
            #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $eval_test, ": $result\n";
            next unless defined $result;
            next if $seen{$result}++;
            push @results, [ $locale, $result ];
            last if @results > $max_threads;
        }

        last if @results > $locales_min;
        @locales = reverse @locales;
    }

    $locales_max_so_far = @results if @results > $locales_max_so_far;

    my %branch = ( eval_string => $eval_test, test_cases => \@results );
    if ($sub_category) {
        $tests{$category_name}{$sub_category} = \%branch;
    }
    else {
        $tests{$category_name} = \%branch;
    }
}

sub get_messages_catalog
{
    my $catalog = "";
    foreach my $error (sort keys %!) {
        #print STDERR __FILE__, ": ", __LINE__, ": $error\n"; 
        no warnings;
        $! = eval "&POSIX::$error";
        next unless "$!";
        $catalog .= "\n" if $catalog;
        $catalog .= quotemeta "$!";
    }

    return $catalog;
}

foreach my $category (valid_locale_categories()) {
    if ($category eq 'LC_ALL') {
        $has_lc_all = 1;
        next;
    }

    if ($category eq 'LC_MESSAGES') {
        next;
        add_trials('LC_MESSAGES', \&get_messages_catalog);
        next;
    }

    if ($category eq 'LC_NUMERIC') {
        add_trials('LC_NUMERIC', "localeconv()->{decimal_point}");
        next;
    }

    if ($category eq 'LC_MONETARY') {
        add_trials('LC_MONETARY', "localeconv()->{currency_symbol}");
        next;
    }

    if ($category eq 'LC_TIME') {
        add_trials('LC_TIME', "POSIX::strftime($strftime_args)");
        next;
    }

    if ($category eq 'LC_COLLATE') {
        next;
        my $all_chars = quotemeta join "", map { chr } (1..255);
        add_trials('LC_COLLATE', "POSIX::strxfrm(\"$all_chars\")");
        next;
    }

    if ($category eq 'LC_CTYPE') {
        next;
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::lc chr } (0..255)", "lc");
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::uc chr } (0..255)", "uc");
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::fc chr } (0..255)", "fc");
        next;
    }
}

$max_threads = $locales_max_so_far if $locales_max_so_far < $max_threads;
my $tests_expanded = Data::Dumper->Dump([ \%tests ], [ 'tests_ref' ]);
        #print STDERR __FILE__, __LINE__, ": ", $tests_expanded, "\n";


{
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

        use Devel::Peek;

        sub disp_str {
            my \$string = shift;
            return \$string if \$string =~ / ^ [[:print:]]* \\z/xa;

            my \$result = '';
            my \$prev_was_punct = 1; # Beginning is considered punct
            if (utf8::valid(\$string) && utf8::is_utf8(\$string)) {
                use charnames ();
                foreach my \$char (split '', \$string) {

                    # Keep punctuation adjacent to other characters; otherwise
                    # separate them with a blank
                    if (\$char =~ /[[:punct:]]/a) {
                        \$result .= \$char;
                        \$prev_was_punct = 1;
                    }
                    elsif (\$char =~ /[[:print:]]/a) {
                        \$result .= '  ' unless \$prev_was_punct;
                        \$result .= \$char;
                        \$prev_was_punct = 0;
                    }
                    else {
                        \$result .= '  ' unless \$prev_was_punct;
                        my \$name = charnames::viacode(ord \$char);
                        \$result .= (defined \$name) ? \$name : ':unknown:';
                        \$prev_was_punct = 0;
                    }
                }
            }
            else {
                use bytes;
                foreach my \$char (split '', \$string) {
                    if (\$char =~ /[[:punct:]]/a) {
                        \$result .= \$char;
                        \$prev_was_punct = 1;
                    }
                    elsif (\$char =~ /[[:print:]]/a) {
                        \$result .= ' ' unless \$prev_was_punct;
                        \$result .= \$char;
                        \$prev_was_punct = 0;
                    }
                    else {
                        \$result .= ' ' unless \$prev_was_punct;
                        \$result .= sprintf('%02X', ord \$char);
                        \$prev_was_punct = 0;
                    }
                }
            }

            return \$result;
        }

        my \$result = 1;

        my \@threads = map +threads->create(sub {
            my \$corrects=0;

            my \$i   = shift;

            use Data::Dumper;
            my $tests_expanded;
            #print STDERR \"thread \$i: \", __LINE__, ': ', Dumper \$tests_ref;

            sleep .1;
            for my \$iteration (1..5000) {

                for my \$category_name (keys %{\$tests_ref}) {
                    my \$cat_num = eval \"&POSIX::\$category_name\";
                    #print STDERR \"\$@\\n\" if \$@;
                    #print STDERR \"\$category_name: thread=\", threads->tid(), \"; index=\", \$i % scalar \@{\$tests_ref->{\$category_name}{test_cases}}, \"\\n\";
                    my \$locale = \$tests_ref->{\$category_name}{test_cases}[\$i % scalar \@{\$tests_ref->{\$category_name}{test_cases}}][0];
                    #print STDERR __FILE__, ': ', __LINE__, \": \$cat_num : \$category_name : \$locale\";
                    setlocale(\$cat_num, \$locale);
                }

                threads->yield();

                for my \$category_name (keys %{\$tests_ref}) {
                    my \$expected = \$tests_ref->{\$category_name}{test_cases}[\$i % scalar \@{\$tests_ref->{\$category_name}{test_cases}}][1];
                    my \$got = eval \"\$tests_ref->{\$category_name}{eval_string}\";
                    #print STDERR __FILE__, ': ', __LINE__, \": \$category_name : \$expected\\n\";
                    #print STDERR __FILE__, ': ', __LINE__, ': got     ', eval \"\$tests_ref->{\$category_name}{eval_string}\", \"\\n\";
                    if (\$got eq \$expected) {
                        \$corrects++;
                    }
                    else {
                        print STDERR \"thread \", threads->tid(), \" failed in iteration \$iteration after getting \$corrects previous corrects\n\";
                        print STDERR \"expected \", disp_str(\$expected), \"\\n\";
                        print STDERR \"     got \", disp_str(\$got), \"\\n\";
                        return 0;
                    }
                }

            }

            return 1;

            }, \$_), (1..$max_threads);
        \$result &= \$_->join for splice \@threads;
        print \$result",
    1, {}, "Verify there were no failures with simultaneous running threads"
    );
}

__END__

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

        }), \$_, (0..3);
        \$result &= \$_->join for splice \@threads;
        print \$result",
    1, {}, "Verify there were no failures with simultaneous running threads"
    );
}

done_testing();
#                    my \$eval_string = \$tests_ref->{eval_string};
#                    my \$expected = \$tests_ref->{test_cases}[\$i % scalar \$tests_ref->{test_cases}];
#
#                if (ti
#                if (POSIX::strftime($strftime_args) eq \$time_value) {
#                    \$correct++;
#                }
#                else {
#                    print STDERR 'tid=', threads->tid(), ' correct so far=', \$correct, ' locale=', \$time_locale, qq(\\n);
#                    Dump \$time_value;
#                    Dump POSIX::strftime($strftime_args);
#                }
            my \$lc_time = \$tests_ref->{LC_TIME};
            if (\$lc_time) {
            my ( \$C_time_locale, \$C_time_value ) = each %{\$lc_time->[0]};
            #print STDERR __LINE__, ': ', Dumper \$i, \$lc_time->[0];
            my ( \$time_locale, \$time_value) = each %{\$lc_time->[\$i]}; # % (scalar \$lc_time->*\@)]};
            #Dump \$time_locale;
            #Dump \$time_value;
