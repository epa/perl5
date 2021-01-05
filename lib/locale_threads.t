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
    eval { require POSIX; POSIX->import(qw(errno_h locale_h  unistd_h )) };
    if ($@) {
	skip_all("could not load the POSIX module"); # running minitest?
    }
}

use Time::HiRes qw(time usleep);

my $thread_count = 5;
my $iterations = 5000;

# reset the locale environment
local @ENV{'LANG', (grep /^LC_/, keys %ENV)};

SKIP: { # perl #127708
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

sub C_first ()
{
    $a eq 'C' ? -1 : $b eq 'C' ? 1 : $a cmp $b;
}

# December 18, 1987
my $strftime_args = "'%c', 0, 0, , 12, 18, 11, 87";

my $has_lc_all = 0;
my $dumper_times;
my %tests_prep;

my @dates;
use Data::Dumper;
$Data::Dumper::Sortkeys=1;
$Data::Dumper::Useqq = 1;
$Data::Dumper::Deepcopy = 1;

sub add_trials($$)
{
    my $category_name = shift;
    my $op = shift;
    my $sub_category = shift;

    my $category_number = eval "&POSIX::$category_name";
    die "$@" if $@;

    my %results;
    my %seen;
    foreach my $locale (sort C_first find_locales($category_name)) {
        use locale;
        next unless setlocale($category_number, $locale);

        my $result = eval $op;
        die "$category_name: '$op': $@" if $@;
        #$result = "" if $locale eq 'C' && ! defined $result;
        next unless defined $result;
        if ($seen{$result}++) {
            push $tests_prep{$category_name}{duplicate_results}{$op}->@*, [ $locale, $result ];
        }
        else {
            $tests_prep{$category_name}{$locale}{$op} = $result;
        }
    }
}

my $max_messages = 10;
my $get_messages_catalog = <<EOT;
my \@catalog;

#print STDERR __FILE__, ": ", __LINE__, Dumper \%!;
foreach my \$error (keys %!) {
    #print STDERR __FILE__, ": ", __LINE__, ": error name \$error\\n";
    my \$number = eval "Errno::\$error";
    #print STDERR __FILE__, ": ", __LINE__, ": number \$number\\n";
    \$! = \$number;
    my \$description = "\$!";
    #print STDERR __FILE__, ": ", __LINE__, ": description = \$description\\n";
    next unless "\$description";
    #print STDERR __FILE__, ": ", __LINE__, ": description = \$description\\n";
    \$catalog[\$number] = quotemeta "\$description";
}
for (my \$i = 0; \$i < \@catalog; \$i++) {
    splice \@catalog, \$i, 1 unless defined \$catalog[\$i];
}
    
#print STDERR __FILE__, ": ", __LINE__, ": Results: ", Dumper \@catalog;

join "\n", \@catalog;
EOT

foreach my $category (valid_locale_categories()) {
        #print STDERR __FILE__, ": ", __LINE__, ": $category\n"; 
    if ($category eq 'LC_ALL') {
        $has_lc_all = 1;
        next;
    }

    if ($category eq 'LC_MESSAGES') {
        add_trials('LC_MESSAGES', $get_messages_catalog);
        next;
    }

    if ($category eq 'LC_NUMERIC') {
        add_trials('LC_NUMERIC', "localeconv()->{decimal_point}");

        # Use a variable to avoid constant folding hiding real bugs
        add_trials('LC_NUMERIC', 'my $in = 4.2; sprintf("%g", $in)');
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
        add_trials('LC_COLLATE', 'quotemeta join "", sort reverse map { chr } (1..255)');
        add_trials('LC_COLLATE', 'my $string = quotemeta join "", map { chr } (1..255); POSIX::strxfrm($string)');
        next;
    }

    if ($category eq 'LC_CTYPE') {
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::lc chr } (0..255)");
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::uc chr } (0..255)");
        add_trials('LC_CTYPE', "quotemeta join '', map { CORE::fc chr } (0..255)");
        next;
    }
}

#__END__
#print STDERR __FILE__, __LINE__, ": ", Dumper \%tests_prep;

my @tests;
for my $i (1 .. $thread_count) {
    foreach my $category (keys %tests_prep) {
        foreach my $locale (sort C_first keys $tests_prep{$category}->%*) {
            next if $locale eq 'duplicate_results';
            foreach my $op (keys $tests_prep{$category}{$locale}->%*) {
                my %temp = ( op => $op,
                             expected => $tests_prep{$category}{$locale}{$op}
                           );
                $tests[$i]->{$category}{locale_name} = $locale;
                push $tests[$i]->{$category}{locale_tests}->@*, \%temp;
            }
            delete $tests_prep{$category}{$locale};
            last;
        }

        if (! exists $tests[$i]->{$category}{locale_tests}) {
            #print STDERR __FILE__, ": ", __LINE__, ": i=$i $category: missing tests\n";
            #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $tests_prep{$category}{duplicate_results};
            foreach my $op (keys $tests_prep{$category}{duplicate_results}->%*) {
                my $locale_result_pair = shift $tests_prep{$category}{duplicate_results}{$op}->@*;
                next unless $locale_result_pair;
                #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $locale_result_pair;

                my $locale = $locale_result_pair->[0];
                my $expected = $locale_result_pair->[1];
                $tests[$i]->{$category}{locale_name} = $locale;
                my %temp = ( op => $op,
                             expected => $expected
                           );
                push $tests[$i]->{$category}{locale_tests}->@*, \%temp;
           }
        }

        # If still didn't get any results, as a last resort copy the previous
        # one.
        if (! exists $tests[$i]->{$category}{locale_tests}) {
              $tests[$i  ]->{$category}{locale_name}
            = $tests[$i-1]->{$category}{locale_name};

              $tests[$i  ]->{$category}{locale_tests}
            = $tests[$i-1]->{$category}{locale_tests};
#print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $category, $i, $tests[$i  ]->{$category};
        }
    }
}

#print STDERR __FILE__, ": ", __LINE__, ": ", Dumper \@tests;
#__END__

#$thread_count = $locales_max_so_far if $locales_max_so_far < $thread_count;
my $tests_expanded = Data::Dumper->Dump([ \@tests ], [ 'all_tests_ref' ]);
my $starting_time = sprintf "%.16e", (time() + 1) * 1_000_000;

    {
        # See if multiple threads can simultaneously change the locale, and give
        # the expected radix results.  On systems without a comma radix locale,
        # run this anyway skipping the use of that, to verify that we dont
        # segfault
        fresh_perl_is("
            use threads;
            use strict;
            use warnings;
            use POSIX qw(locale_h);
            use utf8;
            use Time::HiRes qw(time usleep);

            use Devel::Peek;

            my \$result = 1;
            my \@threads = map +threads->create(sub {
                #print STDERR 'thread ', threads->tid, ' started, sleeping ', $starting_time - time() * 1_000_000, \" usec\\n\";
                my \$sleep_time = $starting_time - time() * 1_000_000;
                usleep(\$sleep_time) if \$sleep_time > 0;
                threads->yield();

                #print STDERR 'thread ', threads->tid, \" taking off\\n\";

                my \$i = shift;

                my $tests_expanded;

                # Tests for just this thread
                my \$thread_tests_ref = \$all_tests_ref->[\$i];

                my \%corrects;

                foreach my \$category_name (keys \$thread_tests_ref->%*) {
                    my \$cat_num = eval \"&POSIX::\$category_name\";
                    print STDERR \"\$@\\n\" if \$@;

                    my \$locale = \$thread_tests_ref->{\$category_name}{locale_name};
                    setlocale(\$cat_num, \$locale);
                    \$corrects{\$category_name} = 0;
                }

                use locale;

                for my \$iteration (1..$iterations) {
                    for my \$category_name (keys \$thread_tests_ref->%*) {
                        foreach my \$test (\$thread_tests_ref->{\$category_name}{locale_tests}->@*) {
                            my \$expected = \$test->{expected};
                            my \$got = eval \$test->{op};
                            if (\$got eq \$expected) {
                                \$corrects{\$category_name}++;
                            }
                            else {
                                \$|=1;
                                my \$locale = \$thread_tests_ref->{\$category_name}{locale_name};
                                print STDERR \"thread \", threads->tid(), \" failed in iteration \$iteration for locale \$locale \$category_name op='\$test->{op}' after getting \$corrects{\$category_name} previous corrects\n\";
                                print STDERR \"expected:\\n\";
                                Dump \$expected;
                                print STDERR \"\\ngot:\\n\";
                                Dump \$got;
                                return 0;
                            }
                        }
                    }
                }

                return 1;

            }, \$_), (1..$thread_count);
        \$result &= \$_->join for splice \@threads;
        print \$result",
    1, {}, "Verify there were no failures with simultaneous running threads"
    );
}

done_testing();
