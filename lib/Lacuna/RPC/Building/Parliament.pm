package Lacuna::RPC::Building::Parliament;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'Lacuna::RPC::Building';
use Guard qw(guard);

sub app_url {
    return '/parliament';
}

sub model_class {
    return 'Lacuna::DB::Result::Building::Module::Parliament';
}

sub view_propositions {
    my ($self, $session_id, $building_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    my @out;
    my $propositions = $building->propositions->search({ status => 'Pending'});
    while (my $proposition = $propositions->next) {
        $proposition->check_status;
        push @out, $proposition->get_status($empire);
    }
    return {
        status          => $self->format_status($empire, $building->body),
        propositions    => \@out,
    };
}

sub view_laws {
    my ($self, $session_id, $body_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $body = $self->get_body($empire, $body_id);
    my @out;
    my $laws = $body->laws;
    while (my $law = $laws->next) {
        push @out, $law->get_status($empire);
    }
    return {
        status          => $self->format_status($empire, $body),
        laws            => \@out,
    };
}

sub cast_vote {
    my ($self, $session_id, $building_id, $proposition_id, $vote) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot vote in parliament.'];
    }
    my $building = $self->get_building($empire, $building_id);
    my $cache = Lacuna->cache;
    my $lock = 'vote_lock_'.$empire->id;
    if ($cache->get($lock, $proposition_id)) {
        confess [1013, 'You already have a vote in process for this proposition.'];
    }
    $cache->set($lock,$proposition_id,1,5);
    my $guard = guard {$cache->delete($lock,$proposition_id);};
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->find($proposition_id);
    unless (defined $proposition) {
        confess [1002, 'Proposition not found.'];
    }
    $proposition->cast_vote($empire, $vote);
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_fire_bfg {
    my ($self, $session_id, $building_id, $x, $y, $reason) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 30) {
        confess [1013, 'Parliament must be level 30 to propose using the BFG.',30];
    }
    Lacuna::Verify->new(content=>\$reason, throws=>[1005,'Reason cannot be empty.',$reason])->not_empty;
    Lacuna::Verify->new(content=>\$reason, throws=>[1005,'Reason cannot contain HTML tags or entities.',$reason])->no_tags;
    Lacuna::Verify->new(content=>\$reason, throws=>[1005,'Reason cannot contain profanity.',$reason])->no_profanity;
    my $body = Lacuna->db->resultset('Lacuna::DB::Result::Map::Body')->search({x=>$x, y=>$y},{rows=>1})->single;
    unless (defined $body) {
        confess [1002, 'Could not find the target body.'];
    }
    unless ($body->isa('Lacuna::DB::Result::Map::Body::Planet')) {
        confess [1009, 'Target is not a planet.'];
    }
    $self->body->in_jurisdiction($body);
    my $name = $body->name.' ('.$body->x.','.$body->y.')';
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'FireBfg',
        name            => 'Fire BFG at '.$name,
        description     => 'Fire the BFG at '.$name.' from the station named "'.$building->body->name.'". Reason cited: '.$reason,
        scratch         => { body_id => $body->id },
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_writ {
    my ($self, $session_id, $building_id, $title, $writ) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 4) {
        confess [1013, 'Parliament must be level 4 to propose a writ.',4];
    }
    Lacuna::Verify->new(content=>\$title, throws=>[1005,'Title cannot be empty.',$title])->not_empty;
    Lacuna::Verify->new(content=>\$title, throws=>[1005,'Title cannot contain any of these characters: {}<>&;@',$title])->no_restricted_chars;
    Lacuna::Verify->new(content=>\$title, throws=>[1005,'Title must be less than 30 characters.',$title])->length_lt(30);
    Lacuna::Verify->new(content=>\$title, throws=>[1005,'Title cannot contain profanity.',$title])->no_profanity;
    Lacuna::Verify->new(content=>\$writ, throws=>[1005,'Writ cannot be empty.',$writ])->not_empty;
    Lacuna::Verify->new(content=>\$writ, throws=>[1005,'Writ cannot contain HTML tags or entities.',$writ])->no_tags;
    Lacuna::Verify->new(content=>\$writ, throws=>[1005,'Writ cannot contain profanity.',$writ])->no_profanity;
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'EnactWrit',
        name            => $title,
        description     => $writ,
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_transfer_station_ownership {
    my ($self, $session_id, $building_id, $to_empire_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 6) {
        confess [1013, 'Parliament must be level 6 to transfer station ownership.',6];
    }
    unless ($to_empire_id) {
        confess [1002, 'Must specify an empire id to transfer the station to.'];
    }
    my $to_empire = Lacuna->db->resultset('Lacuna::DB::Result::Empire')->find($to_empire_id);
    unless (defined $to_empire) {
        confess [1002, 'Could not find the empire to transfer the station to.'];
    }
    unless ($to_empire->alliance_id == $empire->alliance_id) {
        confess [1009, 'That empire is not a member of your alliance.'];
    }
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'TransferStationOwnership',
        name            => 'Transfer Station',
        description     => 'Transfer ownership of station named '.$self->body->name.' from '.$self->body->empire->name.' to '.$to_empire->name.'.',
        scratch         => { empire_id => $to_empire->id },
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_seize_star {
    my ($self, $session_id, $building_id, $star_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 7) {
        confess [1013, 'Parliament must be level 7 to seize control of a star.',7];
    }
    unless ($star_id) {
        confess [1002, 'Must specify a star id to seize.'];
    }
    my $star = Lacuna->db->resultset('Lacuna::DB::Result::Map::Star')->find($star_id);
    unless (defined $star) {
        confess [1002, 'Could not find the star.'];
    }
    unless ($star->station_id) {
        confess [1009, 'That star is already controlled by a station.'];
    }
    $building->body->in_range_of_influence($star);
    unless ($building->body->influence_remaining > 0) {
        confess [1009, 'You do not have enough influence to control another star.'];
    }
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'SeizeStar',
        name            => 'Seize '.$star->name,
        description     => 'Seize control of '.$star->name.' ('.$star->x.','.$star->y.'), and apply all present laws to said star and its inhabitants.',
        scratch         => { star_id => $star->id },
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_repeal_law {
    my ($self, $session_id, $building_id, $law_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 5) {
        confess [1013, 'Parliament must be level 5 to repeal a low.',5];
    }
    unless ($law_id) {
        confess [1002, 'Must specify a law id to repeal.'];
    }
    my $law = $self->body->laws->find($law_id);
    unless (defined $law) {
        confess [1002, 'Could not find the law.'];
    }
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'RepealLaw',
        name            => 'Repeal '.$law->name,
        description     => 'Repeal the law described as: '.$law->description,
        scratch         => { law_id => $law->id },
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}

sub propose_rename_star {
    my ($self, $session_id, $building_id, $star_id, $star_name) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    if ($empire->current_session->is_sitter) {
        confess [1015, 'Sitters cannot create propositions.'];
    }
    my $building = $self->get_building($empire, $building_id);
    unless ($building->level >= 8) {
        confess [1013, 'Parliament must be level 8 to rename a star.',8];
    }
    unless ($star_id) {
        confess [1002, 'Must specify a star id to rename.'];
    }
    my $star = Lacuna->db->resultset('Lacuna::DB::Result::Map::Star')->find($star_id);
    unless (defined $star) {
        confess [1002, 'Could not find the star.'];
    }
    unless ($star->station_id == $self->body_id) {
        confess [1009, 'That star is not controlled by this station.'];
    }
    Lacuna::Verify->new(content=>\$star_name, throws=>[1000,'Name not available.',$star_name])
        ->length_gt(2)
        ->length_lt(31)
        ->no_restricted_chars
        ->no_profanity
        ->no_padding
        ->not_ok(Lacuna->db->resultset('Lacuna::DB::Result::Map::Star')->search({name=>$star_name, 'star_id'=>{'!='=>$star->id}})->count); # name available
    my $proposition = Lacuna->db->resultset('Lacuna::DB::Result::Propositions')->new({
        type            => 'RenameStar',
        name            => 'Rename '.$star->name,
        description     => 'Rename '.$star->name.' ('.$star->x.','.$star->y.') to '.$star_name.'.',
        scratch         => { star_id => $star->id, name => $star_name },
        proposed_by_id  => $empire->id,
    });
    $proposition->station($building->body);
    $proposition->proposed_by($empire);
    $proposition->insert;
    return {
        status      => $self->format_status($empire, $building->body),
        proposition => $proposition->get_status($empire),
    };
}


__PACKAGE__->register_rpc_method_names(qw(propose_rename_star propose_repeal_law propose_seize_star propose_transfer_station_ownership view_propositions view_laws cast_vote propose_fire_bfg propose_writ));

no Moose;
__PACKAGE__->meta->make_immutable;

