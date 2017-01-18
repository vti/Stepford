package Stepford::Runner::StepTree;

use strict;
use warnings;
use namespace::autoclean;

our $VERSION = '0.003010';

use List::AllUtils qw( all any first_index max sort_by );
use Scalar::Util qw( refaddr );
use Stepford::Error;
use Stepford::Types qw(
    ArrayOfSteps
    ArrayRef
    Bool
    HashRef
    Logger
    Maybe
    Num
    Step
);
use Try::Tiny qw( catch try );

use Moose;
use MooseX::StrictConstructor;

has config => (
    is       => 'ro',
    isa      => HashRef,
    required => 1,
);

has logger => (
    is       => 'ro',
    isa      => Logger,
    required => 1,
);

has step => (
    is       => 'ro',
    isa      => Step,
    required => 1,
);

has _step_classes => (
    is       => 'ro',
    isa      => ArrayOfSteps,
    init_arg => 'step_classes',
    required => 1,
);

has _step_object => (
    is      => 'ro',
    isa     => Step,
    lazy    => 1,
    builder => '_build_step_object',
);

has last_run_time => (
    is      => 'ro',
    isa     => Maybe [Num],
    writer  => 'set_last_run_time',
    clearer => '_clear_last_run_time',
    lazy    => 1,
    default => sub { shift->_step_object->last_run_time },
);

has step_productions_as_hashref => (
    is      => 'ro',
    isa     => HashRef,
    writer  => 'set_step_productions_as_hashref',
    clearer => '_clear_step_productions_as_hashref',
    lazy    => 1,
    default => sub { shift->_step_object->productions_as_hashref },
);

has _children_steps => (
    traits   => ['Array'],
    init_arg => 'children_steps',
    is       => 'ro',
    isa      => ArrayRef ['Stepford::Runner::StepTree'],

    # required => 1,
    lazy    => 1,
    builder => '_build_children_steps',
    handles => {

        # XXX - the code should be refactored so modifying the tree is not
        # necessary
        add_child => 'push',
    },
);

has _production_map => (
    is       => 'ro',
    isa      => HashRef [Step],
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_production_map',
);

has has_been_processed => (
    is      => 'ro',
    isa     => Bool,
    default => 0,
    writer  => 'set_has_been_processed',
);

sub traverse {
    my $self = shift;
    my $cb   = shift;

    $_->traverse($cb) for @{ $self->_children_steps };
    $cb->($self);
    return;
}

sub get_child_index {
    my $self  = shift;
    my $child = shift;

    return first_index { refaddr $child eq refaddr $_}
    @{ $self->_children_steps };
}

sub _build_production_map {
    my $self = shift;

    my %map;
    for my $class ( @{ $self->_step_classes } ) {
        for my $attr ( map { $_->name } $class->productions ) {
            next if exists $map{$attr};

            $map{$attr} = $class;
        }
    }

    return \%map;
}

sub _build_children_steps {
    my $self = shift;

    my $map  = $self->_production_map;
    my $step = $self->step;

    my @children;
    my %deps;

    # We remove the current class from step classes for children to prevent
    # cycles
    my @step_classes = grep { $step ne $_ } @{ $self->_step_classes };

    for my $dep ( map { $_->name } $step->dependencies ) {
        Stepford::Error->throw( "Cannot resolve a dependency for $step."
                . " There is no step that produces the $dep attribute."
                . ' Do you have a cyclic dependency?' )
            unless $map->{$dep};

        Stepford::Error->throw(
            "A dependency ($dep) for $step resolved to the same step.")
            if $map->{$dep} eq $step;

        $self->logger->debug(
            "Dependency $dep for $step is provided by $map->{$dep}");

        my $child_step = $map->{$dep};
        next if exists $deps{$child_step};
        $deps{$child_step} = 1;

        push @children, Stepford::Runner::StepTree->new(
            config       => $self->config,
            logger       => $self->logger,
            step         => $child_step,
            step_classes => \@step_classes,
        );
    }

    return [ sort_by { $_->step } @children ];
}

sub _build_step_object {
    my $self = shift;
    my $args = $self->_constructor_args_for_class;

    $self->logger->debug( $self->step . '->new' );
    return $self->step->new($args);
}

sub _constructor_args_for_class {
    my $self = shift;

    my $class  = $self->step;
    my $config = $self->config;

    my %args;
    for my $init_arg (
        grep { defined }
        map  { $_->init_arg } $class->meta->get_all_attributes
        ) {

        $args{$init_arg} = $config->{$init_arg}
            if exists $config->{$init_arg};
    }

    my %productions = $self->_children_productions;

    for my $dep ( map { $_->name } $class->dependencies ) {

        # XXX - I'm not sure this error is reachable. We already check that a
        # class's declared dependencies can be satisfied while building the
        # tree. That said, it doesn't hurt to leave this check in here, and it
        # might help illuminate bugs in the Runner itself.
        Stepford::Error->throw(
            "Cannot construct a $class object. We are missing a required production: $dep"
        ) unless exists $productions{$dep};

        $args{$dep} = $productions{$dep};
    }

    $args{logger} = $self->logger;

    return \%args;
}

sub maybe_run_step {
    my $self                 = shift;
    my $force_step_execution = shift;

    die 'Tried running '
        . $self->step
        . ' when not all children have been processed.'
        unless $self->children_have_been_processed;

    if ( $self->has_been_processed ) {
        $self->logger->info( $self->step . ' already ran. Skipping.' );
        return;
    }

    if (  !$force_step_execution
        && $self->_is_up_to_date ) {
        $self->logger->info( 'Skipping ' . $self->step );
        $self->set_has_been_processed(1);
        return;
    }

    $self->logger->info( 'Running ' . $self->step );

    $self->_step_object->run;

    $self->set_has_been_processed(1);
    $self->_clear_last_run_time;
    $self->_clear_step_productions_as_hashref;

    return;
}

sub _is_up_to_date {
    my $self = shift;

    my $class = $self->step;

    unless ( defined $self->last_run_time ) {
        $self->logger->debug("No last run time for $class.");
        return 0;
    }

    unless ( @{ $self->_children_steps } ) {
        $self->logger->debug("No previous steps for $class.");
        return 1;
    }

    my @children_last_run_times
        = map { $_->last_run_time } @{ $self->_children_steps };

    unless ( all { defined } @children_last_run_times ) {
        $self->logger->debug(
            "A previous step for $class does not have a last run time.");
        return 0;
    }

    my $max_previous_step_last_run_time = max(@children_last_run_times);
    $self->logger->info( "Last run time for $class is "
            . $self->last_run_time
            . ". Previous steps last run time is $max_previous_step_last_run_time."
    );
    my $step_is_up_to_date
        = $self->last_run_time > $max_previous_step_last_run_time;

    $self->logger->info( "$class is "
            . ( $step_is_up_to_date ? q{} : 'not ' )
            . 'up to date.' );

    return $step_is_up_to_date;
}

sub productions {
    my $self = shift;

    return (
        $self->_children_productions,
        %{ $self->step_productions_as_hashref },
    );
}

sub _children_productions {
    my $self = shift;

    return
        map { %{ $_->step_productions_as_hashref } }
        @{ $self->_children_steps };
}

sub children_have_been_processed {
    my $self = shift;

    all { $_->has_been_processed } @{ $self->_children_steps };
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Contains the step dependency graph

__END__

=pod

=for Pod::Coverage .*

=head1 DESCRIPTION

This is an internal class and has no user-facing parts.
