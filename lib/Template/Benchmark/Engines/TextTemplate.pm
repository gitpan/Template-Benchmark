package Template::Benchmark::Engines::TextTemplate;

use warnings;
use strict;

use base qw/Template::Benchmark::Engine/;

use Text::Template;

use File::Spec;

our $VERSION = '0.99_04';

our %feature_syntaxes = (
    literal_text              => <<END_OF_TEMPLATE,
foo foo foo foo foo foo foo foo foo foo foo foo
foo foo foo foo foo foo foo foo foo foo foo foo
foo foo foo foo foo foo foo foo foo foo foo foo
foo foo foo foo foo foo foo foo foo foo foo foo
foo foo foo foo foo foo foo foo foo foo foo foo
END_OF_TEMPLATE
    scalar_variable           =>
        '{$scalar_variable}',
    hash_variable_value       =>
        '{$hash_variable{hash_value_key}}',
    array_variable_value      =>
        '{$array_variable[ 2 ]}',
    deep_data_structure_value =>
        '{$this{is}{a}{very}{deep}{hash}{structure}}',
    array_loop_value          =>
        '{ $OUT .= $_ foreach @array_loop; }',
    hash_loop_value           =>
        '{ $OUT .= "$_: $hash_loop{$_}" foreach sort( keys( %hash_loop ) ); }',
    records_loop_value        =>
        '{ $OUT .= "$_->{name}: $_->{age}" foreach @records_loop; }',
    array_loop_template       =>
        undef,
    hash_loop_template        =>
        undef,
    records_loop_template     =>
        undef,
    constant_if_literal       =>
        '{ if( 1 ) { $OUT .= "true"; } }',
    variable_if_literal       =>
        '{ if( $variable_if ) { $OUT .= "true"; } }',
    constant_if_else_literal  =>
        '{ if( 1 ) { $OUT .= "true"; } else { $OUT .= "false"; } }',
    variable_if_else_literal  =>
        '{ if( $variable_if_else ) { $OUT .= "true"; } else ' .
        '{ $OUT .= "false"; } }',
    constant_if_template      =>
        undef,
    variable_if_template      =>
        undef,
    constant_if_else_template =>
        undef,
    variable_if_else_template =>
        undef,
    constant_expression       =>
        '{10 + 12}',
    variable_expression       =>
        '{$variable_expression_a * $variable_expression_b}',
    complex_variable_expression =>
        '{ ( ( $variable_expression_a * $variable_expression_b ) + ' .
        '$variable_expression_a - $variable_expression_b ) / ' .
        '$variable_expression_b }',
    constant_function         =>
        q[{substr( 'this has a substring.', 11, 9 )}],
    variable_function         =>
        '{substr( $variable_function_arg, 4, 2 )}',
    );

sub benchmark_descriptions
{
    return( {
        TeTe    =>
            "Text::Template ($Text::Template::VERSION)",
        } );
}

sub benchmark_functions_for_uncached_string
{
    my ( $self ) = @_;

    return( {
        TeTe =>
            sub
            {
                my $t = Text::Template->new(
                    TYPE              => 'STRING',
                    SOURCE            => $_[ 0 ],
                    );
                $t->fill_in( HASH => [ $_[ 1 ], $_[ 2 ] ] );
            },
        } );
}

sub benchmark_functions_for_disk_cache
{
    my ( $self, $template_dir, $cache_dir ) = @_;

    return( undef );
}

sub benchmark_functions_for_shared_memory_cache
{
    my ( $self, $template_dir, $cache_dir ) = @_;

    return( undef );
}

sub benchmark_functions_for_memory_cache
{
    my ( $self, $template_dir, $cache_dir ) = @_;

    return( undef );
}

sub benchmark_functions_for_instance_reuse
{
    my ( $self, $template_dir, $cache_dir ) = @_;
    my ( $t );

    return( {
        TeTe =>
            sub
            {
                $t = Text::Template->new(
                    TYPE   => 'FILE',
                    SOURCE => File::Spec->catfile( $template_dir, $_[ 0 ] ),
                    )
                    unless $t;
                $t->fill_in( HASH => [ $_[ 1 ], $_[ 2 ] ] );
            },
        } );
}

1;

__END__

=pod

=head1 NAME

Template::Benchmark::Engines::TextTemplate - Template::Benchmark plugin for Text::Template.

=head1 SYNOPSIS

Provides benchmark functions and template feature syntaxes to allow
L<Template::Benchmark> to benchmark the L<Text::Template> template
engine.

=head1 AUTHOR

Sam Graham, C<< <libtemplate-benchmark-perl at illusori.co.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-template-benchmark at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Template-Benchmark>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Template::Benchmark::Engines::TextTemplate


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
