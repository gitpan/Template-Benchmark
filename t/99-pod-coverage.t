use strict;
use warnings;
use Test::More;

# Ensure a recent version of Test::Pod::Coverage
my $min_tpc = 1.08;
eval "use Test::Pod::Coverage $min_tpc";
plan skip_all => "Test::Pod::Coverage $min_tpc required for testing POD coverage"
    if $@;

# Test::Pod::Coverage doesn't require a minimum Pod::Coverage version,
# but older versions don't recognize some common documentation styles
my $min_pc = 0.18;
eval "use Pod::Coverage $min_pc";
plan skip_all => "Pod::Coverage $min_pc required for testing POD coverage"
    if $@;

eval "use Pod::Coverage::CountParents";
plan skip_all => "Pod::Coverage::CountParents required for testing POD coverage"
    if $@;


plan tests => 2;

pod_coverage_ok( 'Template::Benchmark',
    { coverage_class => 'Pod::Coverage::CountParents' } );
pod_coverage_ok( 'Template::Benchmark::Engine',
    { coverage_class => 'Pod::Coverage::CountParents' } );

#  TODO: need to be moved into author tests, plugins will fail horribly
#  on machines without the given template engine installed.
#all_pod_coverage_ok( { coverage_class => 'Pod::Coverage::CountParents' } );
