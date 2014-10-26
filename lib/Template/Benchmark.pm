package Template::Benchmark;

use warnings;
use strict;

use Benchmark;

use POSIX qw(tmpnam);
use File::Path qw(mkpath rmtree);
use File::Spec;
use IO::File;

use Module::Pluggable ( search_path => 'Template::Benchmark::Engines',
                        sub_name    => 'engine_plugins' );

our $VERSION = '0.99_10';

my @valid_features = qw/
    literal_text
    scalar_variable
    hash_variable_value
    array_variable_value
    deep_data_structure_value
    array_loop_value
    hash_loop_value
    records_loop_value
    array_loop_template
    hash_loop_template
    records_loop_template
    constant_if_literal
    variable_if_literal
    constant_if_else_literal
    variable_if_else_literal
    constant_if_template
    variable_if_template
    constant_if_else_template
    variable_if_else_template
    constant_expression
    variable_expression
    complex_variable_expression
    constant_function
    variable_function
    /;

my @valid_cache_types = qw/
    uncached_string
    uncached_disk
    disk_cache
    shared_memory_cache
    memory_cache
    instance_reuse
    /;

my %option_defaults = (
    #  Feature options: these should only default on if they're
    #  widely supported, so that the default benchmark covers
    #  most template engines.
    literal_text                => 1,
    scalar_variable             => 1,
    hash_variable_value         => 0,
    array_variable_value        => 0,
    deep_data_structure_value   => 0,
    array_loop_value            => 0,
    hash_loop_value             => 0,
    records_loop_value          => 1,
    array_loop_template         => 0,
    hash_loop_template          => 0,
    records_loop_template       => 1,
    constant_if_literal         => 0,
    variable_if_literal         => 1,
    constant_if_else_literal    => 0,
    variable_if_else_literal    => 1,
    constant_if_template        => 0,
    variable_if_template        => 1,
    constant_if_else_template   => 0,
    variable_if_else_template   => 1,
    constant_expression         => 0,
    variable_expression         => 0,
    complex_variable_expression => 0,
    constant_function           => 0,
    variable_function           => 0,

    #  Cache types.
    uncached_string             => 1,
    uncached_disk               => 1,
    disk_cache                  => 1,
    shared_memory_cache         => 1,
    memory_cache                => 1,
    instance_reuse              => 1,

    #  Other options.
    template_repeats => 30,
    duration         => 10,
    style            => 'none',
    keep_tmp_dirs    => 0,

    #  Plugin control.
    only_plugin      => {},
    skip_plugin      => {},
    );

#  Which engines to try first as the 'reference output' for templates.
#  Note that this is merely a matter of author convenience: all template
#  engine outputs must match, this merely determines which should be
#  cited as 'correct' in the case of a mismatch.  This should generally
#  be a template engine that provides most features, otherwise it won't
#  be an _available_ template engine when we need it.
#  For author convenience I'm using Template::Sandbox as the prefered
#  reference, however Template::Toolkit will make a better reference
#  choice once this module has stabilized.
my $reference_preference = 'TS';

my $var_hash1 = {
    scalar_variable => 'I is a scalar, yarr!',
    hash_variable   => {
        'hash_value_key' =>
            'I spy with my little eye, something beginning with H.',
        },
    array_variable   => [ qw/I have an imagination honest/ ],
    this => { is => { a => { very => { deep => { hash => {
        structure => "My god, it's full of hashes.",
        } } } } } },
    template_if_true  => 'True dat',
    template_if_false => 'Nay, Mister Wilks',
    };
my $var_hash2 = {
    array_loop => [ qw/five four three two one coming ready or not/ ],
    hash_loop  => {
        aaa => 'first',
        bbb => 'second',
        ccc => 'third',
        ddd => 'fourth',
        eee => 'fifth',
        },
    records_loop => [
        { name => 'Joe Bloggs',      age => 16,  },
        { name => 'Fred Bloggs',     age => 23,  },
        { name => 'Nigel Bloggs',    age => 43,  },
        { name => 'Tarquin Bloggs',  age => 143, },
        { name => 'Geoffrey Bloggs', age => 13,  },
        ],
    variable_if      => 1,
    variable_if_else => 0,
    variable_expression_a => 20,
    variable_expression_b => 10,
    variable_function_arg => 'Hi there',
    };

sub new
{
    my $this = shift;
    my ( $self, $class, $options );

    $self = {};
    $class = ref( $this ) || $this;
    bless $self, $class;

    $self->{ options } = {};
    $options = $self->{ options };
    while( my $opt = shift )
    {
        if( $opt eq 'only_plugin' or $opt eq 'skip_plugin' )
        {
            my $val = shift();
            $options->{ $opt } ||= {};
            if( ref( $val ) )
            {
                $val = [ grep { $val->{ $_ } } keys( %{$val} ) ]
                    if ref( $val ) eq 'HASH';
                foreach ( @{$val} )
                {
                    $options->{ $opt }->{ $_ } = 1;
                }
            }
            else
            {
                $options->{ $opt }->{ $val } = 1;
            }
        }
        else
        {
            $self->{ options }->{ $opt } = shift();
        }
    }
    foreach my $opt ( keys( %option_defaults ) )
    {
        $options->{ $opt } = $option_defaults{ $opt }
            unless defined $options->{ $opt };
    }

    delete $options->{ only_plugin }
        unless scalar( keys( %{$options->{ only_plugin }} ) );
    delete $options->{ skip_plugin }
        unless scalar( keys( %{$options->{ skip_plugin }} ) );

    $self->{ engines } = [];
    $self->{ engine_errors } = {};
    foreach my $plugin ( $self->engine_plugins() )
    {
        my $leaf = _engine_leaf( $plugin );
        if( $options->{ only_plugin } )
        {
            next unless $options->{ only_plugin }->{ $leaf };
        }
        if( $options->{ skip_plugin } )
        {
            next if $options->{ skip_plugin }->{ $leaf };
        }
        eval "use $plugin";
        if( $@ )
        {
            $self->engine_error( $leaf, "Engine module load failure: $@" );
        }
        else
        {
            push @{$self->{ engines }}, $plugin;
        }
    }

    $self->{ template_dir } = tmpnam();
    $self->{ cache_dir }    = $self->{ template_dir } . '.cache';
    #  TODO: failure check.
    mkpath( $self->{ template_dir } );
    mkpath( $self->{ cache_dir } );

    $self->{ cache_types } =
        [ grep { $options->{ $_ } } @valid_cache_types ];
    #  TODO: sanity-check some are left.

    $self->{ features } =
        [ grep { $options->{ $_ } } @valid_features ];
    #  TODO: sanity-check some are left.

    $self->{ templates }           = {};
    $self->{ benchmark_functions } = {};
    $self->{ descriptions }        = {};
    $self->{ engine_for_tag }      = {};
    ENGINE: foreach my $engine ( @{$self->{ engines }} )
    {
        my ( %benchmark_functions, $template_dir, $cache_dir, $template,
            $template_filename, $fh, $descriptions, $missing_syntaxes, $leaf );

        $leaf = _engine_leaf( $engine );

        $template_dir =
            File::Spec->catfile( $self->{ template_dir }, $leaf );
        $cache_dir    =
            File::Spec->catfile( $self->{ cache_dir },    $leaf );
        #  TODO: failure check
        mkpath( $template_dir );
        mkpath( $cache_dir );

        foreach my $cache_type ( @{$self->{ cache_types }} )
        {
            my ( $method, @method_args, $functions );

            $method = "benchmark_functions_for_${cache_type}";

            next unless $engine->can( $method );

            @method_args = ();
            push @method_args, $template_dir
                unless $cache_type eq 'uncached_string';
            push @method_args, $cache_dir
                unless $cache_type =~ /^uncached/o;

            eval { $functions = $engine->$method( @method_args ); };
            if( $@ )
            {
                $self->engine_error( $leaf,
                    "Error calling ${method}(): $@" );
                next;
            }

            next unless $functions and scalar( keys( %{$functions} ) );

            $benchmark_functions{ $cache_type } = $functions;
        }

        unless( %benchmark_functions )
        {
            $self->engine_error( $leaf, 'No matching benchmark functions.' );
            next ENGINE;
        }

        $template = '';
        $missing_syntaxes = '';
        foreach my $feature ( @{$self->{ features }} )
        {
            my ( $feature_syntax );

            $feature_syntax = $engine->feature_syntax( $feature );
            if( defined( $feature_syntax ) )
            {
                $template .= $feature_syntax . "\n";
            }
            else
            {
                $missing_syntaxes .= ' ' . $feature;
            }
        }

        if( $missing_syntaxes )
        {
            $self->engine_error( $leaf,
                "No syntaxes provided for:$missing_syntaxes." );
            next ENGINE;
        }

        $template = $template x $options->{ template_repeats };

        $template_filename =
            File::Spec->catfile( $template_dir, $leaf . '.txt' );
        $fh = IO::File->new( "> $template_filename" );
        unless( $fh )
        {
            $self->engine_error( $leaf,
                "Unable to write $template_filename: $!" );
            next ENGINE;
        }
        $fh->print( $template );
        $fh->close();

        $template_filename = $leaf . '.txt';

        $descriptions = $engine->benchmark_descriptions();

        foreach my $type ( keys( %benchmark_functions ) )
        {
            $self->{ benchmark_functions }->{ $type } ||= {};

            foreach my $tag ( keys( %{$benchmark_functions{ $type }} ) )
            {
                my ( $function );

                $function = $benchmark_functions{ $type }->{ $tag };
                if( $type =~ /_string$/ )
                {
                    $self->{ benchmark_functions }->{ $type }->{ $tag } =
                        sub
                        {
                            $function->( $template,
                                $var_hash1, $var_hash2 );
                        };
                }
                else
                {
                    $self->{ benchmark_functions }->{ $type }->{ $tag } =
                        sub
                        {
                            $function->( $template_filename,
                                $var_hash1, $var_hash2 );
                        };
                }
                #  TODO: warn on duplicates.
                $self->{ descriptions }->{ $tag }   = $descriptions->{ $tag };
                $self->{ engine_for_tag }->{ $tag } = $leaf;
            }
        }
    }

    #  Strip any cache types that ended up with no functions.
    $self->{ cache_types } = [
        grep { $self->{ benchmark_functions }->{ $_ } }
            @{$self->{ cache_types }}
        ];

    return( $self );
}

sub benchmark
{
    my ( $self ) = @_;
    my ( $duration, $style, $result, $reference, @outputs, $errors );

    $duration = $self->{ options }->{ duration };
    $style    = $self->{ options }->{ style };
    $errors   = {};

    #  First up, check each benchmark function produces the same
    #  output as all the others.  This also serves to ensure that
    #  the caches become populated for those benchmarks that are
    #  cached.
    #  We run the benchmark function twice, and use the output
    #  of the second, this is to make sure we're using the output
    #  of the cached template, otherwise we could end up with a
    #  function that produces the right output when building the
    #  cache but then benchmarks insanely well because there's
    #  an error in running the cached version so it no-ops all
    #  the expensive work.
    @outputs = ();
    $reference = 0;
    foreach my $type ( @{$self->{ cache_types }} )
    {
        foreach my $tag
            ( keys( %{$self->{ benchmark_functions }->{ $type }} ) )
        {
            my ( $output );

            #  First to cache.
            eval { $self->{ benchmark_functions }->{ $type }->{ $tag }->(); };
            if( $@ )
            {
                $self->engine_error(
                    $self->{ engine_for_tag }->{ $tag },
                    "Error running benchmark function for $tag: $@",
                    $errors );
                delete $self->{ benchmark_functions }->{ $type }->{ $tag };
                next;
            }
            #  And second for output.
            $output = eval {
                $self->{ benchmark_functions }->{ $type }->{ $tag }->();
                };
            if( $@ )
            {
                $self->engine_error(
                    $self->{ engine_for_tag }->{ $tag },
                    "Error running benchmark function for $tag: $@",
                    $errors );
                delete $self->{ benchmark_functions }->{ $type }->{ $tag };
                next;
            }
            push @outputs, [ $type, $tag, $output ];
            $reference = $#outputs if $tag eq $reference_preference;
        }
        #  Prune if all our functions have errored and been pruned.
        delete $self->{ benchmark_functions }->{ $type }
            unless %{$self->{ benchmark_functions }->{ $type }};
    }

    #  Strip any cache types that ended up with no functions.
    $self->{ cache_types } = [
        grep { $self->{ benchmark_functions }->{ $_ } }
            @{$self->{ cache_types }}
        ];

    unless( @outputs )
    {
        $result =
            {
                result => 'NO BENCHMARKS TO RUN',
            };
        $result->{ errors } = $errors if %{$errors};
        return( $result );
    }

#use Data::Dumper;
#print "Outputs: ", Data::Dumper::Dumper( \@outputs ), "\n";

    #  TODO: this nasty hackery is surely telling me I need a
    #        Template::Benchmark::Result object.
    $result = {
        result    => 'MISMATCHED TEMPLATE OUTPUT',
        reference =>
            {
                type   => $outputs[ $reference ]->[ 0 ],
                tag    => $outputs[ $reference ]->[ 1 ],
                output => $outputs[ $reference ]->[ 2 ],
            },
        descriptions => { %{$self->{ descriptions }} },
        failures => [],
        };
    $result->{ errors } = $errors if %{$errors};
    foreach my $output ( @outputs )
    {
        push @{$result->{ failures }},
            {
                type   => $output->[ 0 ],
                tag    => $output->[ 1 ],
                output => defined( $output->[ 2 ] ) ?
                          $output->[ 2 ] : "[no content returned]\n",
            }
            if !defined( $output->[ 2 ] ) or
               $output->[ 2 ] ne $result->{ reference }->{ output };
    }

    return( $result ) unless $#{$result->{ failures }} == -1;

    #  OK, all template output matched, time to do the benchmarks.

    delete $result->{ failures };
    $result->{ result } = 'SUCCESS';

    $result->{ start_time } = time();
    $result->{ title } = 'Template Benchmark @' .
        localtime( $result->{ start_time } );

    $result->{ benchmarks } = [];
    if( $duration )
    {
        foreach my $type ( @{$self->{ cache_types }} )
        {
            my ( $timings, $comparison );

            $timings = Benchmark::timethese( -$duration,
                $self->{ benchmark_functions }->{ $type }, $style );
            $comparison = Benchmark::cmpthese( $timings, $style );

            push @{$result->{ benchmarks }},
                {
                    type       => $type,
                    timings    => $timings,
                    comparison => $comparison,
                };
        }
    }

    return( $result );
}

sub DESTROY
{
    my ( $self ) = @_;

    #  Use a DESTROY to clean up, so that we occur in case of errors.
    if( $self->{ options }->{ keep_tmp_dirs } )
    {
        print "Not removing cache dir ", $self->{ cache_dir }, "\n"
            if $self->{ cache_dir };
        print "Not removing template dir ", $self->{ template_dir }, "\n"
            if $self->{ template_dir };
    }
    else
    {
        rmtree( $self->{ cache_dir } )    if $self->{ cache_dir };
        rmtree( $self->{ template_dir } ) if $self->{ template_dir };
    }
}

sub default_options { return( %option_defaults ); }
sub valid_cache_types { return( @valid_cache_types ); }
sub valid_features { return( @valid_features ); }

sub engines
{
    my ( $self ) = @_;
    return( @{$self->{ engines }} );
}

sub features
{
    my ( $self ) = @_;
    return( @{$self->{ features }} );
}

sub engine_errors
{
    my ( $self ) = @_;
    return( $self->{ engine_errors } );
}

sub engine_error
{
    my ( $self, $engine, $error, $errors ) = @_;
    my ( $leaf );

    $errors = $self->{ engine_errors } unless $errors;
    $leaf   = _engine_leaf( $engine );

    #  TODO: warn if an option asks us to?

    $errors->{ $leaf } ||= [];
    push @{$errors->{ $leaf }}, $error;
}

sub number_of_benchmarks
{
    my ( $self ) = @_;
    my ( $num_benchmarks );

    $num_benchmarks = 0;
    foreach my $type ( @{$self->{ cache_types }} )
    {
        $num_benchmarks +=
            scalar( keys( %{$self->{ benchmark_functions }->{ $type }} ) );
    }

    return( $num_benchmarks );
}

sub estimate_benchmark_duration
{
    my ( $self ) = @_;
    my ( $duration );

    $duration = $self->{ options }->{ duration };

    return( $duration * $self->number_of_benchmarks() );
}

sub _engine_leaf
{
    my ( $engine ) = @_;

    $engine =~ /\:\:([^\:]*)$/;
    return( $1 || $engine );
}

1;

__END__

=pod

=head1 NAME

Template::Benchmark - Pluggable benchmarker to cross-compare template systems.

=head1 SYNOPSIS

    use Template::Benchmark;

    my $bench = Template::Benchmark->new(
        duration            => 5,
        repeats             => 1,
        array_loop          => 1,
        shared_memory_cache => 0,
        );

    my $result = $bench->benchmark();

    if( $result->{ result } eq 'SUCCESS' )
    {
        ...
    }

=head1 DESCRIPTION

L<Template::Benchmark> provides a pluggable framework for cross-comparing
performance of various template engines across a range of supported features
for each, grouped by caching methodology.

If that's a bit of a mouthful... have you ever wanted to find out the relative
performance of template modules that support expression parsing when running
with a shared memory cache?  Do you even know which ones I<allow> you to do
that?  This module lets you find that sort of thing out.

If you're just after results, then you should probably start with the
L<benchmark_template_engines> script first, it provides a commandline
UI onto L<Template::Benchmark> and gives you human-readable reports
as a reply rather than a raw hashref, it also supports JSON output if
you want to dump the report somewhere in a machine-readable format.

=head1 IMPORTANT CONCEPTS AND TERMINOLOGY

=head2 Template Engines

L<Template::Benchmark> is built around a plugin structure using
L<Module::Pluggable>, it will look under C<Template::Benchmark::Engines::*>
for I<template engine> plugins.

Each of these plugins provides an interface to a different
I<template engine> such as L<Template::Toolkit>,
L<HTML::Template>, L<Template::Sandbox> and so on.

=head2 Cache Types

I<cache types> determine the source of the template and the caching
mechanic applied, currently there are the following I<cache types>:
I<uncached_string>, I<uncached_disk>, I<disk_cache>, I<shared_memory_cache>,
I<memory_cache> and I<instance_reuse>.

For a full list, and for an explanation of what they represent,
consult the L<Template::Benchmark::Engine> documentation.

=head2 Template Features

I<Template features> are a list of features supported by the various
I<template engines>, not all are implemented by all I<engines> although
there's a core set of I<features> supported by all I<engines>.

I<Features> can be things like I<literal_text>, I<records_loop>,
I<scalar_variable>, I<variable_expression> and so forth.

For a full list, and for an explanation of what they represent,
consult the L<Template::Benchmark::Engine> documentation.

=head2 Benchmark Functions

Each I<template engine> plugin provides the means to produce a
I<benchmark function> for each I<cache types>.

The I<benchmark function> is an anonymous sub that is expected
to be passed the template, and two hashrefs of template variables,
and is expected to return the output of the processed template.

These are the functions that will be benchmarked, and generally
consist (depending on the I<template engine>) of a call to the
template constructor and template processing functions.

Each plugin can return several I<benchmark functions> for a given
I<cache type>, so each is given a tag to use as a name and
a description for display, this allows plugins like
L<Template::Benchmark::Engines::TemplateToolkit> to contain
benchmarks for L<Template::Toolkit>, L<Template::Toolkit> running
with L<Template::Stash::XS>, and various other options.

Each of these will run as an independent benchmark even though they're
provided by the same plugin.

=head2 Supported or Unsupported?

Throughout this document are references to whether a I<template feature>
or I<cache type> is supported or unsupported in the I<template engine>.

But what constitutes "unsupported"?

It doesn't neccessarily mean that it's I<impossible> to perform that task
with the given I<template engine>, but generally if it requires some
significant chunk of DIY code or boilerplate or subclassing by the
developer using the I<template engine>, it should be considered to be
I<unsupported> by the I<template engine> itself.

This of course is a subjective judgement, but a general rule of thumb
is that if you can tell the I<template engine> to do it, it's supported;
and if the I<template engine> allows I<you> to do it, it's I<unsupported>,
even though it's I<possible>.

=head1 HOW Template::Benchmark WORKS

=head2 Construction

When a new L<Template::Benchmark> object is constructed, it attempts
to load all I<template engine> plugins it finds.

It then asks each plugin for a snippet of template to implement each
I<template feature> requested.  If a plugin provides no snippet then
it is assumed that that I<feature> is unsupported by that I<engine>.

Each snippet is then combined into a benchmark template for that
specific I<template engine> and written to a temporary directory,
at the same time a cache directory is set up for that I<engine>.
These temporary directories are cleaned up in the C<DESTROY()> of
the benchmark instance, usually when you let it go out of scope.

Finally, each I<engine> is asked to provide a list of I<benchmark
functions> for each I<cache type> along with a name and description
explaining what the I<benchmark function> is doing.

At this point the L<Template::Benchmark> constructor exits, and you're
ready to run the benchmarks.

=head2 Running the benchmarks

When the calling program is ready to run the benchmarks it calls
C<< $bench->benchmark() >> and then twiddles its thumbs, probably
for a long time.

While this twiddling is going on, L<Template::Benchmark> is busy
running each of the I<benchmark functions> a single time.

The outputs of this initial run are compared and if there are any
mismatches then the C<< $bench->benchmark() >> function exits
early with a result structure indicating the errors as compared
to a reference copy produced by the reference plugin engine.

An important side-effect of this initial run is that the cache
for each I<benchmark function> becomes populated, so that the
cached I<cache types> truly reflect only cached performance
and not the cost of an initial cache miss.

If all the outputs match then the I<benchmark functions> for
each I<cache type> are handed off to the L<Benchmark>
module for benchmarking.

The results of the benchmarks are bundled together and placed
into the results structure that is returned from
C<< $bench->benchmark() >>.

=head1 OPTIONS

New L<Template:Benchmark> objects can be created with the constructor
C<< Template::Benchmark->new( %options ) >>, using any (or none) of the
options below.

=over

=item B<uncached_string> => I<0> | I<1> (default 1)

=item B<uncached_disk> => I<0> | I<1> (default 1)

=item B<disk_cache> => I<0> | I<1> (default 1)

=item B<shared_memory_cache> => I<0> | I<1> (default 1)

=item B<memory_cache> => I<0> | I<1> (default 1)

=item B<instance_reuse> => I<0> | I<1> (default 1)

Each of these options determines which I<cache types> are enabled
(if set to a true value) or disabled (if set to a false value).
At least one of them must be set to a true value for any benchmarks
to be run.

=item B<literal_text> => I<0> | I<1> (default 1)

=item B<scalar_variable> => I<0> | I<1> (default 1)

=item B<hash_variable_value> => I<0> | I<1> (default 0)

=item B<array_variable_value> => I<0> | I<1> (default 0)

=item B<deep_data_structure_value> => I<0> | I<1> (default 0)

=item B<array_loop_value> => I<0> | I<1> (default 0)

=item B<hash_loop_value> => I<0> | I<1> (default 0)

=item B<records_loop_value> => I<0> | I<1> (default 1)

=item B<array_loop_template> => I<0> | I<1> (default 0)

=item B<hash_loop_template> => I<0> | I<1> (default 0)

=item B<records_loop_template> => I<0> | I<1> (default 1)

=item B<constant_if_literal> => I<0> | I<1> (default 0)

=item B<variable_if_literal> => I<0> | I<1> (default 1)

=item B<constant_if_else_literal> => I<0> | I<1> (default 0)

=item B<variable_if_else_literal> => I<0> | I<1> (default 1)

=item B<constant_if_template> => I<0> | I<1> (default 0)

=item B<variable_if_template> => I<0> | I<1> (default 1)

=item B<constant_if_else_template> => I<0> | I<1> (default 0)

=item B<variable_if_else_template> => I<0> | I<1> (default 1)

=item B<constant_expression> => I<0> | I<1> (default 0)

=item B<variable_expression> => I<0> | I<1> (default 0)

=item B<complex_variable_expression> => I<0> | I<1> (default 0)

=item B<constant_function> => I<0> | I<1> (default 0)

=item B<variable_function> => I<0> | I<1> (default 0)

Each of these options sets the corresponding I<template feature> on
or off.  At least one of these must be true for any benchmarks to
run.

=item B<template_repeats> => I<$number> (default 30)

After the template is constructed from the various feature snippets
it gets repeated a number of times to make it longer, this option
controls how many times the basic template gets repeated to form
the final template.

The default of 30 is chosen to provide some form of approximation
of the workload in a "normal" web page.  Given that "how long is
a web page?" has much the same answer as "how long is a piece of
string?" you will probably want to tweak the number of repeats
to suit your own needs.

=item B<duration> => I<$seconds> (default 10)

This option determines how many CPU seconds should be spent running
each I<benchmark function>, this is passed along to L<Benchmark>
as a negative duration, so read the L<Benchmark> documentation if
you want the gory details.

The larger the number the less statistical variance you'll get, the
less likely you are to have temporary blips of the test machine's I/O
or CPU skewing the results, the downside is that your benchmarks will
take corresspondingly longer to run.

The default of 10 seconds seems to give pretty consistent results for
me within +/-1% on a very lightly loaded linux machine.

=item B<style> => I<$string> (default 'none')

This option is passed straight through as the C<style> argument
to L<Benchmark>.  By default it is C<'none'> so that no output is
printed by L<Benchmark>, this also means that you can't see any
results until all the benchmarks are done.  If you set it to C<'auto'>
then you'll see the benchmark results as they happen, but
L<Template::Benchmark> will have no control over the generated output.

Might be handy for debugging or if you're impatient and don't want
pretty reports.

See the L<Benchmark> documentation for valid values for this setting.

=item B<keep_tmp_dirs> => I<0> | I<1> (default 0)

If set to a true value then the temporary directories created for
template files and caches will not be deleted when the
L<Template::Benchmark> instance is destroyed.  Instead, at the point
when they would have been deleted, their location will be printed.

This allows you to inspect the directory contents to see the generated
templates and caches and so forth.

Because the location is printed, and at an unpredictable time, it may
mess up your program output, so this option is probably only useful
while debugging.

=item B<only_plugin> => I<$plugin> (default none)

=item B<skip_plugin> => I<$plugin> (default none)

If either of these two options are set they are used as a 'whitelist'
and 'blacklist' of what I<template engine> plugins to use.

Each can be supplied multiple times to build the whitelist or blacklist,
and expect the leaf module name, or you can supply an arrayref of names,
or a hashref of names with true/false values to toggle them on or off.

  #  This runs only Template::Benchmark::Engines::TemplateSandbox
  $bench = Template::Benchmark->new(
        only_plugin => 'TemplateSandbox',
        );

  #  This skips Template::Benchmark::Engines::MojoTemplate and
  #  Template::Benchmark::Engines::HTMLTemplateCompiled
  $bench = Template::Benchmark->new(
        skip_plugin => 'MojoTemplate',
        skip_plugin => 'HTMLTemplateCompiled',
        );

  #  This runs only Template::Benchmark::Engines::MojoTemplate and
  #  Template::Benchmark::Engines::HTMLTemplateCompiled
  $bench = Template::Benchmark->new(
        only_plugin => {
            MojoTemplate         => 1,
            HTMLTemplateCompiled => 1,
            TemplateSandbox      => 0,
            },
        );

=back

=head1 PUBLIC METHODS

=over

=item I<$benchmark> = B<< Template::Benchmark->new( >> I<< %options >> B<)>

This is the constructor for L<Template::Benchmark>, it will return
a newly constructed benchmark object, or throw an exception explaining
why it couldn't.

The options you can pass in are covered in the L</"OPTIONS"> section
above.

=item I<$result> = B<< $benchmark->benchmark() >>

Run the benchmarks as set up by the constructor.  You can run
C<< $benchmark->benchmark() >> multiple times if you wish to
reuse the same benchmark options.

The structure of the C<$result> hashref is covered in L</"BENCHMARK RESULTS">
below.

=item I<%defaults> = B<< Template::Benchmark->default_options() >>

Returns a hash of the valid options to the constructor and their
default values.  This can be used to keep external programs up-to-date
with what options are available in case new ones are added or the
defaults are changed.  This is what L<benchmark_template_engines>
does in fact.

=item I<@cache_types> = B<< Template::Benchmark->valid_cache_types() >>

Returns a list of the valid I<cache types>.
This can be used to keep external programs up-to-date
with what I<cache types> are available in case new ones are added.
This is what L<benchmark_template_engines> does in fact.

=item I<@features> = B<< Template::Benchmark->valid_features() >>

Returns a list of the valid I<template features>.
This can be used to keep external programs up-to-date
with what I<template features> are available in case new ones are added.
This is what L<benchmark_template_engines> does in fact.

=item B<< $errors = $benchmark->engine_errors() >>

Returns a hashref of I<engine> plugin to an arrayref of error messages
encountered while trying to enable to given plugin for a benchmark.

This may be errors in loading the module or a list of I<template features>
the I<engine> didn't support.

=item B<< $benchmark->engine_error( >> I<$engine>, I<$error_message> B<)>

Pushes I<$error_message> onto the list of error messages for the
engine plugin I<$engine>..

=item I<$number> = B<< $benchmark->number_of_benchmarks() >>

Returns a count of how many I<benchmark functions> will be run.

=item I<$seconds> = B<< $benchmark->estimate_benchmark_duration() >>

Return an estimate, in seconds, of how long it will take to run all
the benchmarks.

This estimate currently isn't a very good one, it's basically the
duration multiplied by the number of I<benchmark functions>, and
doesn't count factors like the overhead of running the benchmarks,
or the fact that the duration is a minimum duration, or the initial
run of the I<benchmark functions> to build the cache and compare
outputs.

It still gives a good lower-bound for how long the benchmark will
run, and maybe I'll improve it in future releases.

=item I<@engines> = B<< $benchmark->engines() >>

Returns a list of all I<template engine plugins> that were successfully
loaded.

Note that this does B<not> mean that all those I<template engines>
support all requested I<template features>, it merely means there
wasn't a problem loading their module.

=item I<@features> = B<< $benchmark->features() >>

Returns a list of all I<template features> that were enabled during
construction of the L<Template::Benchmark> object.

=back

=head1 BENCHMARK RESULTS

The C<< $benchmark->benchmark() >> method returns a results hashref,
this section documents the structure of that hashref.

Firstly, all results returned have a C<result> key indicating the
type of result, this defines the format of the rest of the hashref
and whether the benchmark run was a success or why it failed.

=over

=item C<SUCCESS>

This indicates that the benchmark run completed successfully, there
will be the following additional information:

  {
      result       => 'SUCCESS',
      start_time   => 1265738228,
      title        => 'Template Benchmark @Tue Feb  9 17:57:08 2010',
      descriptions =>
          {
             'HT'    =>
                'HTML::Template (2.9)',
             'TS_CF' =>
                'Template::Sandbox (1.02) with Cache::CacheFactory (1.09) caching',
          },
      reference    =>
          {
              type => 'uncached_string',
              tag    => 'TS',
              output => template output,
          },
      benchmarks   =>
          [
              {
                 type     => 'uncached_string',
                 timings    => Benchmark::timethese() results,
                 comparison => Benchmark::cmpthese() results,
              },
              {
                 type     => 'memory_cache',
                 timings    => Benchmark::timethese() results,
                 comparison => Benchmark::cmpthese() results,
              },
              ...
          ],
  }

=item C<NO BENCHMARKS TO RUN>

  {
      result       => 'NO BENCHMARKS TO RUN',
  }

=item C<MISMATCHED TEMPLATE OUTPUT>

  {
      result    => 'MISMATCHED TEMPLATE OUTPUT',
      reference =>
          {
              type   => 'uncached_string',
              tag    => 'TS',
              output => template output,
          },
      failures =>
          [
              {
                  type   => 'disk_cache',
                  tag    => 'TT',
                  output => template output,
              },
              ...
          ],
  }

=back

=head1 WRITING YOUR OWN TEMPLATE ENGINE PLUGINS

All I<template engine> plugins reside in the C<Template::Benchmark::Engines>
namespace and inherit the L<Template::Benchmark::Engine> class.

See the L<Template::Benchmark::Engine> documentation for details on writing
your own plugins.

=head1 UNDERSTANDING THE RESULTS

This section aims to give you a few pointers when analyzing the results
of a benchmark run, some points are obvious, some less so, and most need
to be applied with some degree of intelligence to know when they're
applicable or not.

Hopefully they'll prove useful.

If you're wondering what all the numbers mean, the documentation for
L<Benchmark> will probably be more helpful.

=over

=item memory_cache vs instance_reuse

Comparing the I<memory_cache> and I<instance_reuse> times for an I<engine>
should generally give you some idea of the overhead of the caching system
used by the I<engine> - if the times are close then they're using a good
caching system, if the times are wildly divergent then you might want to
implement your own cache instead.

=item uncached_string vs instance_reuse or memory_cache

Comparing the I<uncached_string> vs the I<instance_reuse> or the
I<memory_cache> (I<instance_reuse> is better if you can) times for an
I<engine> should give you an indication of how costly the parse and
compile phase for a I<template engine> is.

=item uncached_string or uncached_disk represents a cache miss

The I<uncached_string> or I<uncached_disk> benchmark represents a
cache miss, so comparing it to the cache system you intend to use
will give you an idea of how much you'll hurt whenever a cache
miss occurs.

If you know how likely a cache miss is to happen, you can combine the
results of the two benchmarks proportionally to get a better estimate
of performance, and maybe compare that between different engines.

Estimating cache misses is a tricky art though, and can be mitigated
by a number of measures, or complicated by miss stampedes and so forth,
so don't put too much weight on it either.

=item Increasing repeats emphasises template performance

Increasing the length of the template by increasing the C<template_repeats>
option I<usually> places emphasis on the ability of the I<template engine>
to process the template vs the overhead of reading the template, fetching
it from the cache, placing the variables into the template namespace and
so forth.

For the most part those overheads are fixed cost regardless of length of
the template (fetching from disk or cache will have a, usually small, linear
component), whereas actually executing the template will have a linear
cost based on the repeats.

This means that for small values of repeats you're spending proportionally
more time on overheads, and for large values of repeats you're spending
more time on running the template.

If a I<template engine> has higher-than-average overheads, it will be
favoured in the results (ie, it will rank higher than otherwise) if you
run with a high C<template_repeats> value, and will be hurt in the
results if you run with a low C<template_repeats> value.

Inverting that conclusion, if an I<engine> moves up in the results when
you run with long repeats, or moves down in the results if you run with
short repeats, it follows that the I<engine> probably has high overheads
in I/O, instantiation, variable import or somewhere.

=item deep_data_structure_value and complex_variable_expression are stress tests

Both the C<deep_data_structure_value> and C<complex_variable_expression>
I<template features> are designed to be I<stress test> versions of a
more basic feature.

By comparing C<deep_data_structure_value> vs C<hash_variable_value>
you should be able to glean an indication of how well the I<template engine>
performs at navigating its way through its variable stash (to borrow
L<Template::Toolkit> terminology).

If an I<engine> gains ranks moving from C<hash_variable_value> to
C<deep_data_structure_value> then you know it has a more-efficient-than-average
implementation of its stash, and if it loses ranks then you know it
has a less-efficient-than-average implementation.

Similarly, by comparing C<complex_variable_expression> and
C<variable_expression> you can draw conclusions about the I<template engine's>
expression execution speed.

=item constant vs variable features

Several I<template features> have C<constant> and C<variable> versions,
these indicate a version that is designed to be easily optimizable
(the C<constant> one) and a version that cannot be optimized (the
C<variable> one).

By comparing timings for the two versions, you can get a feel for
whether (and how much) constant-folding optimization is done by a
I<template engine>.

Whether this is of interest to you depends entirely on how you
construct and design your templates, but generally speaking, the
larger and more modular your template structure is, the more likely
you are to have bits of constant values "inherited" from parent
templates (or config files) that could be optimized in this manner.

This is one of those cases where only you can judge whether it is
applicable to your situation or not, L<Template::Benchmark> merely
provides the information so you can make that judgement.

=item duration only effects accuracy

The benchmarks are carefully designed so that any one-off costs from
setting up the benchmark are not included in the benchmark results
itself.

This means that there I<should> be no change in the results from
increasing or decreasing the benchmark duration, except to reduce the
size of the error resulting from background load on the machine.

If a I<template engine> gets consistently better (or worse) results
as duration is changed, while other I<template engines> are unchanged
(give or take statistical error), it indicates that something is
wrong with either the I<template engine>, the plugin or something
else - either way the results of the benchmark should be regarded
as suspect until the cause has been isolated.

=back

=head1 KNOWN ISSUES AND BUGS

=over

=item Test suite is non-existent

The current test-suite is laughable and basically only tests documentation
coverage.

Once I figure out what to test and how to do it, this should change, but
at the moment I'm drawing a blank.

=item Results structure too terse

The results structure could probably do with more information such
as what options were set and what version of benchmark/plugins were
used.

This would be helpful for anything wishing to archive benchmark
results, since it may (will!) influence how comparable results are.

=back

=head1 AUTHOR

Sam Graham, C<< <libtemplate-benchmark-perl at illusori.co.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-template-benchmark at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Template-Benchmark>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Template::Benchmark


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Template-Benchmark>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Template-Benchmark>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Template-Benchmark>

=item * Search CPAN

L<http://search.cpan.org/dist/Template-Benchmark/>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to Paul Seamons for creating the the bench_various_templaters.pl
script distributed with L<Template::Alloy>, which was the ultimate
inspiration for this module.

=head1 COPYRIGHT & LICENSE

Copyright 2010 Sam Graham.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut
