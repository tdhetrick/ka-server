package KA::DB::Result::Propositions::MembersOnlyExcavation;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'KA::DB::Result::Propositions';

before pass => sub {
    my ($self) = @_;
    my $law = KA->db->resultset('KA::DB::Result::Laws')->new({
        name        => $self->name,
        description => $self->description,
        type        => 'MembersOnlyExcavation',
        station_id  => $self->station_id,
    })->insert;
};

no Moose;
__PACKAGE__->meta->make_immutable(inline_constructor => 0);
