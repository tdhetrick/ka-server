package KA::DB::Result::Map::Body::Planet;

use Moose;
use Carp;
use utf8;
no warnings qw(uninitialized);
extends 'KA::DB::Result::Map::Body';
use KA::Constants qw(FOOD_TYPES ORE_TYPES BUILDABLE_CLASSES SPACE_STATION_MODULES);
use List::Util qw(shuffle max min none sum);
use KA::Util qw(randint format_date random_element);
use DateTime;
use Data::Dumper;
use Scalar::Util qw(weaken);

no warnings 'uninitialized';

use experimental "switch";

__PACKAGE__->has_many('fleets','KA::DB::Result::Fleet','body_id');
__PACKAGE__->has_many('_plans','KA::DB::Result::Plan','body_id');
__PACKAGE__->has_many('glyph','KA::DB::Result::Glyph','body_id');
__PACKAGE__->has_many('waste_chains', 'KA::DB::Result::WasteChain','planet_id');
__PACKAGE__->has_many('out_supply_chains', 'KA::DB::Result::SupplyChain','planet_id');
__PACKAGE__->has_many('in_supply_chains', 'KA::DB::Result::SupplyChain','target_id');

has plan_cache => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_plan_cache',
    clearer => 'clear_plan_cache',
);

sub fleets_travelling {
    my ($self) = @_;

    my $fleets_rs = $self->fleets->search_rs({
        task    => 'Travelling',
    });
    return $fleets_rs;
}

sub _build_plan_cache {
    my ($self) = @_;
    my $plans = [];
    my $plan_rs = $self->_plans->search({});
    while (my $plan = $plan_rs->next) {
        $plan->body($self);
        weaken($plan->{_relationship_data}{body});
        push @$plans,$plan;
    }
    return $plans;
}

# Sort plans by name (asc), by level (asc), by extra_build_level (desc)
sub sorted_plans {
    my ($self) = @_;

    my @sorted_plans = sort {
            $a->class->sortable_name cmp $b->class->sortable_name 
        ||  $a->level <=> $b->level
        ||  $a->extra_build_level <=> $b->extra_build_level
        } @{$self->plan_cache};
    return \@sorted_plans;
}

sub _delete_building {
    my ($self, $building) = @_;

    my $i = 0;
    BUILDING:
    foreach my $b (@{$self->building_cache}) {
        if ($b->id == $building->id) {
            my @buildings = @{$self->building_cache};
            splice(@buildings, $i, 1);
            $self->building_cache(\@buildings);
            last BUILDING;
        }
        $i++;
    }
    $self->update;
}
sub _delete_plan {
    my ($self, $plan) = @_;

    my $i = 0;
    BUILDING:
    foreach my $p (@{$self->plan_cache}) {
        if ($p->id == $plan->id) {
            my @plans = @{$self->plan_cache};
            splice(@plans, $i, 1);
            $self->plan_cache(\@plans);
            last BUILDING;
        }
        $i++;
    }
    $self->update;
}

# delete buildings passed in as an array reference
sub delete_buildings {
    my ($self, $buildings) = @_;

    foreach my $building (@$buildings) {
        $self->_delete_building($building);
        $building->delete;
    }
    $self->needs_recalc(1);
    $self->needs_surface_refresh(1);
    $self->update;
}

sub delete_one_plan {
    my ($self, $plan) = @_;

    $self->delete_many_plans($plan, 1);
}

sub delete_many_plans {
    my ($self, $plan, $quantity) = @_;

    if ($plan->quantity > $quantity) {
        $plan->quantity($plan->quantity - $quantity);
        $plan->update;
    }
    else {
        $self->_delete_plan($plan);
        $plan->delete;
    }
}

sub surface {
    my $self = shift;
    return 'surface-'.$self->image;
}

# return result-set for all fleets defending or orbiting
sub fleets_orbiting {
    my ($self, $where, $reverse) = @_;

    my $order = '-asc';
    if ($reverse) {
        $order = '-desc';
    }
    $where->{task} = { in => ['Defend','Orbiting'] };
    return $self->fleets->search(
        $where,
        {
            order_by    => { $order => 'date_available' },
        }
    );
}

# return the number of ships and fleets being built on this planet
sub fleets_building {
    my ($self) = @_;

    my ($sum) = KA->db->resultset('Fleet')->search({
        body_id => $self->id,
        task    => ['Building','Repairing'],
        }, {
        "+select" => [
            { count => 'id' },
            { sum   => 'quantity' },
        ],
        "+as" => [qw(number_of_fleets number_of_ships)],
    });

    return ($sum->get_column('number_of_fleets'), $sum->get_column('number_of_ships'));
}



# claim the planet
sub claim {
    my ($self, $empire_id) = @_;
    return KA->cache->set('planet_claim_lock', $self->id, $empire_id, 60 * 60 * 24 * 3); # lock it
}

# I suspect that making this a 'default' acts as a sort of cache
# which ensures that we only see the first empire to claim this planet
has is_claimed => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return KA->cache->get('planet_claim_lock', $self->id);
    }
);

sub claimed_by {
    my $self = shift;
    my $empire_id = $self->is_claimed;
    return $empire_id ? KA->db->resultset('KA::DB::Result::Empire')->find($empire_id) : undef;    
}

# add a glyph to this planet
sub add_glyph {
  my ($self, $type, $num_add) = @_;

  $num_add = 1 unless defined($num_add);

  my $glyph = KA->db->resultset('KA::DB::Result::Glyph')->search({
                 type    => $type,
                 body_id => $self->id,
               })->first;
  if (defined($glyph)) {
    my $sum = $num_add + $glyph->quantity;
    $glyph->quantity($sum);
    $glyph->update;
  }
  else {
    $self->glyph->new({
      type     => $type,
      body_id  => $self->id,
      quantity => $num_add,
    })->insert;
  }
}

sub use_glyph {
  my ($self, $type, $num_used) = @_;

  $num_used = 1 unless (defined($num_used));
  my $glyph = KA->db->resultset('KA::DB::Result::Glyph')->search({
                 type    => $type,
                 body_id => $self->id,
               })->first;
  return 0 unless defined($glyph);
  if ($glyph->quantity > $num_used) {
    my $sum = $glyph->quantity - $num_used;
    $glyph->quantity($sum);
    $glyph->update;
  }
  else {
    $num_used = $glyph->quantity;
    $glyph->delete;
  }
  return $num_used;
}

# get a plan with the highest extra build level
sub get_plan {
    my ($self, $class, $level) = @_;

    my ($plan) = sort {$b->extra_build_level <=> $a->extra_build_level} grep {$_->class eq $class and $_->level == $level} @{$self->plan_cache};
    return $plan;
}

# create a new plan for this planet
sub add_plan {
    my ($self, $class, $level, $extra_build_level, $quantity) = @_;
    $quantity = 1 unless defined $quantity;

    # add it
    my ($plan) = grep {
            $_->class eq $class 
        and $_->level == $level 
        and $_->extra_build_level == $extra_build_level,
        } @{$self->plan_cache};
    if ($plan) {
        $plan->quantity($plan->quantity + $quantity);
        $plan->update;
    }
    else {
        $plan = $self->_plans->create({
            body_id             => $self->id,
            class               => $class,
            level               => $level,
            extra_build_level   => $extra_build_level,
            quantity            => $quantity,
        });
        push @{$self->plan_cache}, $plan;
    }
    return $plan;
}

# clean up the planet prior to abandoning it
sub sanitize {
    my ($self) = @_;
    my @buildings = grep {$_->class !~ /Permanent/} @{$self->building_cache};
    $self->delete_buildings(\@buildings);
    for my $building (@{$self->building_cache}) {
        $building->is_upgrading(0);
        $building->update;
    }
    $self->alliance_id(undef);
    $self->_plans->delete;
    $self->glyph->delete;
    $self->waste_chains->delete;
    # do individual deletes so the remote ends can be tidied up too
    foreach my $chain ($self->out_supply_chains) {
        $chain->delete;
    }
    foreach my $chain ($self->in_supply_chains) {
        $chain->delete;
    }
    my $incoming = KA->db->resultset('KA::DB::Result::Fleet')->search({foreign_body_id => $self->id, direction => 'out'});
    while (my $fleet = $incoming->next) {
        $fleet->turn_around->update;
    }
    $self->fleets->delete_all;
    my $enemy_spies = KA->db->resultset('KA::DB::Result::Spies')->search({on_body_id => $self->id});
    while (my $spy = $enemy_spies->next) {
        $spy->on_body_id($spy->from_body_id);
        $spy->task("Idle");
        $spy->update;
    }
    KA->db->resultset('KA::DB::Result::Spies')->search({from_body_id => $self->id})->delete_all;
    KA->db->resultset('KA::DB::Result::Market')->search({body_id => $self->id})->delete_all;
    KA->db->resultset('KA::DB::Result::MercenaryMarket')->search({body_id => $self->id})->delete_all;
    # We will delete all probes (observatory or oracle), note, must recreate oracle probes if the planet is recolonised
    KA->db->resultset('KA::DB::Result::Probes')->search_any({body_id => $self->id})->delete;
    $self->empire_id(undef);
    if ($self->get_type eq 'habitable planet' &&
        $self->size >= 40 && $self->size <= 50 &&
        $self->orbit != 8 &&
        $self->zone ~~ ['1|1','1|-1','-1|1','-1|-1','0|0','0|1','1|0','-1|0','0|-1']) {
        $self->usable_as_starter_enabled(1);
    }
    my @attributes = qw( happiness_hour happiness waste_hour waste_stored waste_capacity
        energy_hour energy_stored energy_capacity water_hour water_stored water_capacity ore_capacity
        rutile_stored chromite_stored chalcopyrite_stored galena_stored gold_stored uraninite_stored bauxite_stored
        goethite_stored halite_stored gypsum_stored trona_stored kerogen_stored methane_stored anthracite_stored
        sulfur_stored zircon_stored monazite_stored fluorite_stored beryl_stored magnetite_stored 
        food_capacity food_consumption_hour lapis_production_hour potato_production_hour apple_production_hour
        root_production_hour corn_production_hour cider_production_hour wheat_production_hour bread_production_hour
        soup_production_hour chip_production_hour pie_production_hour pancake_production_hour milk_production_hour
        meal_production_hour algae_production_hour syrup_production_hour fungus_production_hour burger_production_hour
        shake_production_hour beetle_production_hour lapis_stored potato_stored apple_stored root_stored corn_stored
        cider_stored wheat_stored bread_stored soup_stored chip_stored pie_stored pancake_stored milk_stored meal_stored
        algae_stored syrup_stored fungus_stored burger_stored shake_stored beetle_stored bean_production_hour bean_stored
        restrict_coverage cheese_production_hour cheese_stored
    );
    foreach my $attribute (@attributes) {
        $self->$attribute(0);
    }
    $self->update;
    return $self;
}

before abandon => sub {
    my ($self) = @_;

    if ($self->id eq $self->empire->home_planet_id) {
        confess [1010, 'You cannot abandon your home colony.'];
    }
    $self->sanitize;
};

sub get_ore_status {
    my ($self) = @_;

    my $out;
    foreach my $type (ORE_TYPES) {
        my $arg = "${type}_hour";
        $out->{$arg} = $self->$arg;
        $arg = "${type}_stored";
        $out->{$arg} = $self->$arg;
    }
    return $out;
}

sub get_food_status {
    my ($self) = @_;

    my $out;
    foreach my $type (FOOD_TYPES) {
        my $arg = "${type}_production_hour";
        $out->{"${type}_hour"} = $self->$arg;
        $arg = "${type}_stored";
        $out->{$arg} = $self->$arg;
    }
    return $out;
}

around get_status_lite => sub {
    my ($orig, $self, $empire) = @_;

    my $out = $self->$orig;

    if ($self->empire_id) {
        $out->{empire} = {
            name            => $self->empire->name,
            id              => $self->empire_id,
            alignment       => $self->empire->is_isolationist ? 'hostile-isolationist' : 'hostile',
            is_isolationist => $self->empire->is_isolationist,
        };
        if (defined $empire) {
            if ($empire->id eq $self->empire_id or (
                $self->isa('KA::DB::Result::Map::Body::Planet::Station') and
                $empire->alliance_id and $self->empire->alliance_id == $empire->alliance_id )) {
                $out->{empire}{alignment} = 'self',
            }
            elsif ($empire->alliance_id and $self->empire->alliance_id == $empire->alliance_id) {
                $out->{empire}{alignment} = $self->empire->is_isolationist ? 'ally-isolationist' : 'ally';
            }
        }
    }
    return $out;
};


around get_status => sub {
    my ($orig, $self, $empire) = @_;

    my $out = $orig->($self);
    my $ore;

    
    
    foreach my $type (ORE_TYPES) {
        $ore->{$type} = $self->$type();
    }
    $out->{ore}             = $ore;
    $out->{water}           = $self->water;
    if ($self->empire_id) {
        $out->{empire} = {
            name            => $self->empire->name,
            id              => $self->empire_id,
            alignment       => $self->empire->is_isolationist ? 'hostile-isolationist' : 'hostile',
            is_isolationist => $self->empire->is_isolationist,
        };
        if (defined $empire) {

            # IF this body is owned by the empire
            # OR this body is a station owned by this empires alliance
            # OR the empire is a sitter for this bodies owner

            if ($empire->id eq $self->empire_id 
                or (
                    $self->isa('KA::DB::Result::Map::Body::Planet::Station')
                    and $empire->alliance_id && $self->empire->alliance_id == $empire->alliance_id
                ) 
                or $empire->babies->search({id => $self->empire_id})->count ) {
                
                if ($self->needs_recalc) {
                    $self->tick; # in case what we just did is going to change our stats
                }
                # empires who have disabled the option, don't see incoming ships
                $out->{skip_incoming_ships} = $empire->skip_incoming_ships;
                if (not $empire->skip_incoming_ships) {
                    my $now = time;

                    my $foreign_bodies;
                    # Process all fleets that have already arrived

                    my $incoming_rs = KA->db->resultset('KA::DB::Result::Fleet')->search({
                        foreign_body_id     => $self->id,
                        direction           => 'out',
                        task                => 'Travelling',
                        date_available      => {'<' => DateTime->now.''},
                    });
                    while (my $fleet = $incoming_rs->next) {
                        $foreign_bodies->{$fleet->body_id} = 1;
                    }
                    foreach my $body_id (keys %$foreign_bodies) {
                        my $body = KA->db->resultset('KA::DB::Result::Map::Body')->find($body_id);
                        if ($body) {
                            $body->tick;
                        }
                    }

                    my $num_incoming_ally = 0;
                    my @incoming_ally;
                    # If we are in an alliance, all fleets coming from ally (which are not ourself)
                    if ($self->empire->alliance_id) {
                        my $incoming_ally_rs = KA->db->resultset('KA::DB::Result::Fleet')->search({
                            foreign_body_id     => $self->id,
                            direction           => 'out',
                            task                => 'Travelling',
                            'body.empire_id'    => {'!=' => $empire->id},
                            'empire.alliance_id'  => $empire->alliance_id,
                        },{
                            join                => {body => 'empire'},
                            order_by            => 'date_available',
                        });
                        $num_incoming_ally = $incoming_ally_rs->count;
                        @incoming_ally = $incoming_ally_rs->search({},{rows => 10});
                    }
                    # All fleets coming from ourself
                    my $incoming_own_rs = KA->db->resultset('KA::DB::Result::Fleet')->search({
                        foreign_body_id     => $self->id,
                        direction           => 'out',
                        task                => 'Travelling',
                        'body.empire_id'    => $empire->id,
                    },{
                        join                => 'body',
                        order_by            => 'date_available',
                    });
                    my $num_incoming_own = $incoming_own_rs->count;
                    my @incoming_own = $incoming_own_rs->search({},{rows => 10});

                    # All foreign incoming
                    my $incoming_foreign_rs = KA->db->resultset('KA::DB::Result::Fleet')->search({
                        foreign_body_id     => $self->id,
                        direction           => 'out',
                        task                => 'Travelling',
                        'body.empire_id'    => {'!=' => $empire->id},
                        'empire.alliance_id'  => $self->empire->alliance_id,
                    },{
                        join                => {body => 'empire'},
                        order_by            => 'date_available',
                    });
                    if ($self->empire->alliance_id) {
                        $incoming_foreign_rs = $incoming_foreign_rs->search({
                            'empire.alliance_id' => [
                                {'!=' => $empire->alliance_id},
                                undef,
                            ]
                        });
                    }
                    my $num_incoming_foreign = $incoming_foreign_rs->count;
                    my @incoming_foreign = $incoming_foreign_rs->search({},{rows => 20});

                    $out->{num_incoming_foreign} = $num_incoming_foreign;
                    foreach my $fleet (@incoming_foreign) {
                        push @{$out->{incoming_foreign_fleets}}, {
                            date_arrives    => $fleet->date_available_formatted,
                            is_own          => 0,
                            is_ally         => 0,
                            ships           => $fleet->quantity,
                            id              => $fleet->id,
                        };
                    }
                    $out->{num_incoming_ally} = $num_incoming_ally;
                    foreach my $fleet (@incoming_ally) {
                        push @{$out->{incoming_ally_fleets}}, {
                            date_arrives    => $fleet->date_available_formatted,
                            is_own          => 0,
                            is_ally         => 1,
                            ships           => $fleet->quantity,
                            id              => $fleet->id,
                        };
                    }
                    $out->{num_incoming_own} = $num_incoming_own;
                    foreach my $fleet (@incoming_own) {
                        push @{$out->{incoming_own_fleets}}, {
                            date_arrives    => $fleet->date_available_formatted,
                            is_own          => 1,
                            is_ally         => 0,
                            ships           => $fleet->quantity,
                            id              => $fleet->id,
                        };
                    }
                }
                $out->{needs_surface_refresh} = $self->needs_surface_refresh;
                if ($self->needs_surface_refresh) {
                    $self->surface_version($self->surface_version+1);
                    $self->update;
                }
                $out->{surface_version} = $self->surface_version;

                $out->{empire}{alignment} = 'self';
                $out->{plots_available} = $self->plots_available;
                $out->{building_count}  = $self->building_count;
                $out->{build_queue_size}= $self->build_queue_size;
                $out->{build_queue_len} = $self->build_queue_length;
                $out->{population}      = $self->population;
                $out->{water_capacity}  = $self->water_capacity;
                $out->{water_stored}    = $self->water_stored;
                $out->{water_hour}      = $self->water_hour;
                $out->{energy_capacity} = $self->energy_capacity;
                $out->{energy_stored}   = $self->energy_stored;
                $out->{energy_hour}     = $self->energy_hour;
                $out->{food_capacity}   = $self->food_capacity;
                $out->{food_stored}     = $self->food_stored;
                $out->{food_hour}       = $self->food_hour;
                $out->{ore_capacity}    = $self->ore_capacity;
                $out->{ore_stored}      = $self->ore_stored;
                $out->{ore_hour}        = $self->ore_hour;
                $out->{waste_capacity}  = $self->waste_capacity;
                $out->{waste_stored}    = $self->waste_stored;
                $out->{waste_hour}      = $self->waste_hour;
                $out->{happiness}       = $self->happiness;
                $out->{happiness_hour}  = $self->happiness_hour;
                if ($self->unhappy) {
                    $out->{unhappy_date} = format_date($self->unhappy_date);
                    $out->{propaganda_boost} = $self->propaganda_boost;
                }
                else {
                    $out->{propaganda_boost} = $self->propaganda_boost;
                    if (time < $self->empire->happiness_boost->epoch) {
                        $out->{propaganda_boost} = 75 if ($out->{propaganda_boost} > 75);
                    }
                    else {
                        $out->{propaganda_boost} = 50 if ($out->{propaganda_boost} > 50);
                    }
                }
                $out->{neutral_entry} = format_date($self->neutral_entry);
            }
            elsif ($empire->alliance_id && $self->empire->alliance_id == $empire->alliance_id) {
                $out->{empire}{alignment} = $self->empire->is_isolationist ? 'ally-isolationist' : 'ally';
            }
        }
    }
    return $out;
};

# resource concentrations
use constant rutile         => 1;
use constant chromite       => 1;
use constant chalcopyrite   => 1;
use constant galena         => 1;
use constant gold           => 1;
use constant uraninite      => 1;
use constant bauxite        => 1;
use constant goethite       => 1;
use constant halite         => 1;
use constant gypsum         => 1;
use constant trona          => 1;
use constant kerogen        => 1;
use constant methane        => 1;
use constant anthracite     => 1;
use constant sulfur         => 1;
use constant zircon         => 1;
use constant monazite       => 1;
use constant fluorite       => 1;
use constant beryl          => 1;
use constant magnetite      => 1;
use constant water          => 0;

# BUILDINGS

has population => (
        is      => 'ro',
        lazy    => 1,
        builder => '_build_population',
        );

sub _build_population {
    my ($self) = @_;

    my $population = sum map { $_->population } @{$self->building_cache};
    return $population;
}

has building_count => (
        is      => 'rw',
        lazy    => 1,
        builder => '_build_building_count',
        clearer => 'clear_building_count',
        );

sub _build_building_count {
    my ($self) = @_;
# Bleeders count toward building count, but supply pods don't since they can't be shot down.
    my $count = grep {$_->class !~ /Permanent/ and $_->class !~ /SupplyPod/} @{$self->building_cache}; 
    return $count;
}

# Get buildings of a specified class, ranked highest level first
sub get_buildings_of_class {
    my ($self, $class) = @_;

    my @buildings = sort {$b->level <=> $a->level} grep {$_->class eq $class} @{$self->building_cache};

    return @buildings;
}

# Get the highest level building of a specified class
sub get_building_of_class {
    my ($self, $class) = @_;
    my ($building) = sort {$b->level <=> $a->level} grep {$_->class eq $class} @{$self->building_cache};
    return $building;
}

# Find a building based on it's ID
sub find_building {
    my ($self, $id) = @_;

    my ($building) = grep {$_->id == $id} @{$self->building_cache};
    return $building;
}

# Accessor methods for specific buildings
foreach my $arg (
    [qw(trade Trade)],
    [qw(propulsion Propulsion)],
    [qw(munitions_lab MunitionsLab)],
    [qw(cloaking_lab CloakingLab)],
    [qw(pilot_training PilotTraining)],
    [qw(crashed_ship_site CrashedShipSite)],
    [qw(shipyard Shipyard)],
    [qw(planetary_command PlanetaryCommand)],
    [qw(oversight Oversight)],
    [qw(archaeology Archaeology)],
    ['mining_ministry','Ore::Ministry'],
    [qw(network19 Network19)],
    [qw(development Development)],
    ['oracle', 'Permanent::OracleOfAnid'],
    ['refinery', 'Ore::Refinery'],
    [qw(spaceport SpacePort)],
    [qw(stockpile Stockpile)],
    [qw(capitol Capitol)],
    [qw(embassy Embassy)],
    ) {
    my $method = $arg->[0];
    my $class  = $arg->[1];

    has $method => (
        is      => 'rw',
        lazy    => 1,
        default => sub {
            my ($self) = @_;
            return $self->get_building_of_class("KA::DB::Result::Building::$class");
        },
    );
}

has build_boost => (
    is      => 'rw',
    lazy    => 1,
    clearer => "clear_bb",
    default => sub {
        my $self = shift;

        my $sign = $self->happiness >= 0 ? 1 : -1;
        my $scale = $self->happiness == 0 ? 0 :
            #int
            (
                log(abs($self->happiness)) /
                log(1000)
               );
            #1 - $sign * $scale * ($sign < 0 ? 10 : 2) / 100;
        1 - $sign * $scale * ($sign < 0 ? 150 : 4) / 100;
    },
);


sub is_space_free {
    my ($self, $unclean_x, $unclean_y) = @_;
    my $x = int( $unclean_x );
    my $y = int( $unclean_y );
    return none {$_->x == $x and $_->y == $y} @{$self->building_cache};
}

sub find_free_spaces
{
    my $self = shift;
    my $args = shift // {};
    my $size = $args->{size} // 1; # 4 = SSL (want top-left), 9 = LCOT (want middle)

    # this option is not yet well-tested.
    my $col6 = $args->{outer};
    die "Incorrect usage (size must be one with outer set to true)"
        if $col6 && $size > 1;

    # I have no idea how to make this query in DBIC, so resort to direct
    # SQL calls.
    my $dbh = KA->db->storage->dbh();

    my $gen_tmp = sub {
        my $col = shift;
        my $first = shift;
        join ' ', "select '$first' as $col", map { "union all select '$_'" } @_;
    };
    my $tmp_x = $gen_tmp->('x', $col6 ? (6) : (-5..5));
    my $tmp_y = $gen_tmp->('y', -5..5);

    my $sql = <<"EOSQL";
select v.x,w.y
  from 
   ($tmp_x) as v
  join
   ($tmp_y) as w
  left join
   (select x,y,id from building where body_id = ?) as b
    on 
      b.x = v.x and b.y = w.y
  where
   b.id is null
EOSQL

    my $sth = $dbh->prepare_cached($sql);
    $sth->execute($self->id);

    my $o = $sth->fetchall_arrayref;

    if ($size > 1 && @$o)
    {
        my (@x_offsets,@y_offsets);

        if ($size == 9)
        {
            @x_offsets = @y_offsets = (-1..1);
        }
        elsif ($size == 4)
        {
            @x_offsets = (-1..0);
            @y_offsets = (0..1);
        }
        else
        {
            die "Unexpected size: $size";
        }

        # put them all in a hash for easier tracking.
        my %free;
        for my $c (@$o)
        {
            for my $x_off (@x_offsets)
            {
                for my $y_off (@y_offsets)
                {
                    my $x = $c->[0] + $x_off;
                    my $y = $c->[1] + $y_off;
                    $free{"$x,$y"}++;
                }
            }
        }

        # sort it for easier debugging.
        return [ sort {
            $a->[0] <=> $b->[0] ||
            $a->[1] <=> $b->[1]
        } map {
            [ split ',', $_ ]
        } grep {$free{$_} == $size} keys %free
        ];
    }
    return $o;
}

sub find_free_space {
    my $self = shift;
    my $open_spaces = $self->find_free_spaces();

    confess [1009, 'No free space found.'] unless @$open_spaces;

    return @{random_element($open_spaces)};
}

sub has_outgoing_ships {
    my ($self, $min) = @_;
    my $ships = KA->db->resultset('Ships')->search({
            body_id         => $self->id,
            task            => 'Travelling',
    });
    my $count = $ships->count;
    return 1 if $count >= $min;
    return 0;
}

# Check if the given co-ordinates are a valid building spot
sub check_for_available_build_space {
    my ($self, $unclean_x, $unclean_y) = @_;
    my $x = int( $unclean_x );
    my $y = int( $unclean_y );
    
    if ($x > 5 || $x < -5 || $y > 5 || $y < -5) {
        confess [1009, "That's not a valid space for a building.", [$x, $y]];
    }
    unless ($self->is_space_free($x, $y)) {
        confess [1009, "That space is already occupied.", [$x,$y]]; 
    }
    return 1;
}

# Are there any free building plots available
sub check_plots_available {
    my ($self, $building) = @_;

    if (!$building->isa('KA::DB::Result::Building::Permanent') && $self->plots_available < 1) {
        confess [1009, "You've already reached the maximum number of buildings for this planet.", $self->size];
    }
    return 1;
}

# have we met all the pre-requisites to build this building?
sub has_met_building_prereqs {
    my ($self, $building, $cost) = @_;

    $building->can_build($self);
    $self->has_resources_to_build($building, $cost);
    $self->has_max_instances_of_building($building);
    $self->has_resources_to_operate($building);
    return 1;
}

# can we build this building at this time? 
sub can_build_building {
    my ($self, $building) = @_;

    $self->check_for_available_build_space($building->x, $building->y);
    $self->check_plots_available($building);
    $self->has_room_in_build_queue;
    $self->has_met_building_prereqs($building);
    return $self;
}

has build_queue_size => (
                         is => 'ro',
                         lazy => 1,
                         default => sub {
                             my $self = shift;
                             my $max = 1;
                             my $dev_min = $self->development;
                             $max += $dev_min->effective_level if $dev_min;
                             $max;
                         }
                        );

sub build_queue_length {
    my $self = shift;
    scalar @{$self->builds};
}

# is there room left in the build queue?
sub has_room_in_build_queue {
    my ($self) = @_;

    my $max = 1;
    if (defined $self->development) {
        $max += $self->development->level;
    }
    my $count = @{$self->builds};
    if ($count >= $max) {
        confess [1009, "There's no room left in the build queue.", $max];
    }
    return 1; 
}

use constant operating_resource_names => qw(food_hour energy_hour ore_hour water_hour);

# Get the operating costs when all builds are complete
has future_operating_resources => (
    is      => 'rw',
    clearer => 'clear_future_operating_resources',
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        
        # get current
        my %future;
        foreach my $method ($self->operating_resource_names) {
            $future{$method} = $self->$method;
        }

        # adjust for what's already in build queue
        my @queued_builds = @{$self->builds};
        foreach my $build (@queued_builds) {
            my $other = $build->stats_after_upgrade;
            foreach my $method ($self->operating_resource_names) {
                $future{$method} += $other->{$method} - $build->$method;
            }
        }
        return \%future;
    },
);

# would we have enough resources to operate this building in the future?
sub has_resources_to_operate {
    my ($self, $building) = @_;

    # get future
    my $future = $self->future_operating_resources; 

    # get change for this building
    my $after = $building->stats_after_upgrade;

    # check our ability to sustain ourselves
    foreach my $method ($self->operating_resource_names) {
        my $delta = $after->{$method} - $building->$method;
        # don't allow it if it sucks resources && its sucking more than we're producing
        if ($delta < 0 && $future->{$method} + $delta < 0) {
            my $resource = $method;
            $resource =~ s/(\w+)_hour/$1/;
            confess [1012, "Unsustainable given the current and planned resource consumption. Not enough resources being produced to build this.", $resource];
        }
    }
    return 1;
}

# would we have enough resources to operate everything after this building is demolished?
sub has_resources_to_operate_after_building_demolished {
    my ($self, $building) = @_;

    # get future
    my $planet = $self->future_operating_resources;

    # check our ability to sustain ourselves
    foreach my $method ($self->operating_resource_names) {
        # don't allow it if it sucks resources && its sucking more than we're producing
        if ($planet->{$method} - $building->$method < 0) {
            my $resource = $method;
            $resource =~ s/(\w+)_hour/$1/;
            confess [1012, "Unsustainable. Not enough resources being produced by other sources to destroy this.", $resource];
        }
    }
    return 1;
}

# do we have sufficient resources to construct this building?
sub has_resources_to_build {
    my ($self, $building, $cost) = @_;

    $cost ||= $building->cost_to_upgrade;
    foreach my $resource (qw(food energy ore water)) {
        if ($self->type_stored($resource) < $cost->{$resource}) {
            confess [1011, "Not enough $resource in storage to build this.", $resource];
        }
    }
    if ($cost->{waste} < 0) { # we're spending waste to build a building, which is unusal, but not wrong
        if ($self->waste_stored < abs($cost->{waste})) {
            confess [1011, "Not enough waste in storage to build this.", 'waste'];
        }
    }
    return 1;
}

# do we already have the maximum number of this type of building?
sub has_max_instances_of_building {
    my ($self, $building) = @_;

    return 0 if $building->max_instances_per_planet == 9999999; # TODO what's this all about?
    my $buildings = grep {$_->class eq $building->class} @{$self->building_cache};

    if ($buildings >= $building->max_instances_per_planet) {
        confess [1009, sprintf("You are only allowed %s of these buildings per planet.",$building->max_instances_per_planet)];
    }
}

# return all buildings currently being upgraded
sub builds { 
    my ($self, $reverse) = @_;

    my @buildings = sort {$a->upgrade_ends cmp $b->upgrade_ends} grep {$_->is_upgrading == 1} @{$self->building_cache};
    @buildings = reverse @buildings if $reverse;
    return \@buildings;
}

# get the time when the build queue will be completed 
sub get_existing_build_queue_time {
    my ($self) = @_;

    my ($building) = @{$self->builds(1)};

    return (defined $building) ? $building->upgrade_ends : DateTime->now;
}

sub lock_plot {
    my ($self, $x, $y) = @_;
    return KA->cache->set('plot_contention_lock', $self->id.'|'.$x.'|'.$y, 1, 15); # lock it
}

sub is_plot_locked {
    my ($self, $x, $y) = @_;
    return KA->cache->get('plot_contention_lock', $self->id.'|'.$x.'|'.$y);
}

# put a building on the build queue
sub build_building {
    my ($self, $building, $in_parallel, $no_upgrade) = @_;

    unless ($building->isa('KA::DB::Result::Building::Permanent')) {
        $self->building_count( $self->building_count + 1 );
        $self->plots_available( $self->plots_available - 1 );
        $self->update;
    }
    $building->date_created(DateTime->now);
    $building->body_id($self->id);
    $building->level(0) unless $building->level;
    $building->insert;
    $building->body($self);
    weaken($building->{_relationship_data}{body});
    unless ($no_upgrade) {
        $building->start_upgrade(undef, $in_parallel);
    }
    $self->building_cache([@{$self->building_cache}, $building]);
}

# create a new colony on this planet
sub found_colony {
    my ($self, $empire) = @_;

    $self->empire_id($empire->id);
    $self->usable_as_starter_enabled(0);
    $self->last_tick(DateTime->now);
    $self->update;    

    # Excavators get cleared when being checked for results.

    # award medal
    my $type = ref $self;
    $type =~ s/^.*::(\w\d+)$/$1/;
    $empire->add_medal($type);

    # delete anything that may be on the PCC plot
    my ($building) = grep {$_->x == 0 and $_->y == 0} @{$self->building_cache};
    if (defined $building) {
        $building->delete;
    }

    # add command building
    my $command = KA->db->resultset('KA::DB::Result::Building')->new({
        x       => 0,
        y       => 0,
        class   => 'KA::DB::Result::Building::PlanetaryCommand',
        level   => $empire->growth_affinity - 1,
    });
    $self->build_building($command);
    $command->finish_upgrade;

    my @craters = grep {$_->work eq '{}'} $self->get_buildings_of_class('KA::DB::Result::Building::Permanent::Crater');
    foreach my $crater (@craters) {
        $crater->finish_work->update;
    }

    # recreate virtual probes if there's already an oracle here.
    if (my $oracle = $self->oracle) {
        my $ends = DateTime->now->add(seconds => 60);
        if ($oracle->is_working) {
            $oracle->reschedule_work($ends)
        }
        else {
            $oracle->start_work({}, 60);
        }
    }

    # Initialize body
    my @attributes = qw( happiness_hour happiness waste_hour waste_stored waste_capacity
        energy_hour energy_stored energy_capacity water_hour water_stored water_capacity ore_capacity
        rutile_stored chromite_stored chalcopyrite_stored galena_stored gold_stored uraninite_stored bauxite_stored
        goethite_stored halite_stored gypsum_stored trona_stored kerogen_stored methane_stored anthracite_stored
        sulfur_stored zircon_stored monazite_stored fluorite_stored beryl_stored magnetite_stored 
        food_capacity food_consumption_hour lapis_production_hour potato_production_hour apple_production_hour
        root_production_hour corn_production_hour cider_production_hour wheat_production_hour bread_production_hour
        soup_production_hour chip_production_hour pie_production_hour pancake_production_hour milk_production_hour
        meal_production_hour algae_production_hour syrup_production_hour fungus_production_hour burger_production_hour
        shake_production_hour beetle_production_hour lapis_stored potato_stored apple_stored root_stored corn_stored
        cider_stored wheat_stored bread_stored soup_stored chip_stored pie_stored pancake_stored milk_stored meal_stored
        algae_stored syrup_stored fungus_stored burger_stored shake_stored beetle_stored bean_production_hour bean_stored
        restrict_coverage cheese_production_hour cheese_stored
    );
    foreach my $attribute (@attributes) {
        $self->$attribute(0);
    }
    # add starting resources
    $self->needs_recalc(1);
    $self->tick;
    $self->add_algae(700);
    $self->add_energy(700);
    $self->add_water(700);
    $self->add_ore(700);
    $self->happiness(0);
    $self->update;

    # newsworthy
    $self->add_news(75,'%s founded a new colony on %s.', $empire->name, $self->name);

    return $self;
}

# convert this planet into a station
sub convert_to_station {
    my ($self, $empire) = @_;

    $self->size(3);
    $self->plots_available(0);
    $self->empire_id($empire->id);
#    $self->empire($empire);
#    weaken($self->{_relationship_data}{empire});

    $self->usable_as_starter_enabled(0);
    $self->last_tick(DateTime->now);
    $self->alliance_id($empire->alliance_id);
    $self->class('KA::DB::Result::Map::Body::Planet::Station');
    $self->update;    

    # award medal
    $empire->add_medal('space_station_deployed');

    # clean it
    my @all_buildings = @{$self->building_cache};
    $self->delete_buildings(\@all_buildings);
    $self->_plans->delete;
    $self->glyph->delete;

    # add command building
    my $command = KA->db->resultset('KA::DB::Result::Building')->new({
        x       => 0,
        y       => 0,
        class   => 'KA::DB::Result::Building::Module::StationCommand',
    });
    $self->build_building($command);
    $command->finish_upgrade;

    # add parliament
    my $parliament = KA->db->resultset('KA::DB::Result::Building')->new({
        x       => -1,
        y       => 0,
        class   => 'KA::DB::Result::Building::Module::Parliament',
    });
    $self->build_building($parliament);
    $parliament->finish_upgrade;

    # add warehouse
    my $warehouse = KA->db->resultset('KA::DB::Result::Building')->new({
        x       => 1,
        y       => 0,
        class   => 'KA::DB::Result::Building::Module::Warehouse',
    });
    $self->build_building($warehouse);
    $warehouse->finish_upgrade;

    # add starting resources
    $self->tick;
    $self->add_algae(2500);
    $self->add_energy(2500);
    $self->add_water(2500);
    $self->add_rutile(2500);
    $self->update;

    # newsworthy
    $self->add_news(100,'%s deployed a space station at %s.', $empire->name, $self->name);

    return $self;
}

# total ore concentration of this planet
has total_ore_concentration => (
    is          => 'ro',  
    lazy        => 1,
    default     => sub {
        my ($self) = @_;

        my $tally = 0;
        foreach my $type (ORE_TYPES) {
        $tally += $self->$type;
        }
        return $tally;
        },
        );

# Check if a resource is a food type
sub is_food {
    my ($self, $resource) = @_;

    if (grep {$resource eq $_} (FOOD_TYPES)) {
        return 1;
    }
    return;
}

# Check if a resource is an ore type
sub is_ore {
    my ($self, $resource) = @_;

    if (grep {$resource eq $_} (ORE_TYPES)) {
        return 1;
    }
    return;
}

# convert a resource name into a planet attribute name
sub resource_name {
    my ($self,$resource) = @_;

    if ($self->is_food($resource)) {
        return $resource.'_production_hour';
    }
    return $resource.'_hour';
}

# Recalculate waste and supply chains for this body
sub recalc_chains {
    my ($self) = @_;

    if ($self->trade) {
        $self->trade->recalc_supply_production;
        $self->trade->recalc_waste_production;
    }
}

# recalculate all stats for this body
sub recalc_stats {
    my ($self) = @_;

#    $self->clear_building_cache;

    my %stats = ( needs_recalc => 0 );
    #reset foods and ores
    foreach my $type (FOOD_TYPES) {
        $stats{$type.'_production_hour'} = 0;
    }
    foreach my $type (ORE_TYPES) {
        $stats{$type.'_hour'} = 0;
    }
    $stats{max_berth} = 1;
    #calculate propaganda bonus
    my $spy_boost = KA->db->resultset('Spies')
        ->search(
                 {
                     on_body_id => $self->id,
                     task => 'Political Propaganda',
                     empire_id => $self->empire_id
                 },
                 {
                     select => \[ "floor((me.defense + me.politics_xp)/250 + 0.5)" ],
                     as => "boost"
                 })->get_column("boost")->sum;

    $self->propaganda_boost($spy_boost);
    $self->update;
    #calculate building production
    my ($gas_giant_platforms, $terraforming_platforms, $station_command,
        $pantheon_of_hagness, $ore_production_hour, $ore_consumption_hour,
        $food_production_hour, $food_consumption_hour, $fissure_percent) = 0;
    foreach my $building (@{$self->building_cache}) {
        $stats{waste_capacity}          += $building->waste_capacity;
        $stats{water_capacity}          += $building->water_capacity;
        $stats{energy_capacity}         += $building->energy_capacity;
        $stats{food_capacity}           += $building->food_capacity;
        $stats{ore_capacity}            += $building->ore_capacity;
        $stats{happiness_hour}          += $building->happiness_hour;
        $stats{waste_hour}              += $building->waste_hour;               
        $stats{energy_hour}             += $building->energy_hour;
        $stats{water_hour}              += $building->water_hour;
        $ore_consumption_hour           += $building->ore_consumption_hour;
        $ore_production_hour            += $building->ore_production_hour;
        $stats{food_consumption_hour}   += $building->food_consumption_hour;

        foreach my $type (@{$building->produces_food_items}) {
            my $method = $type.'_production_hour';
            $stats{$method}         += $building->$method();
            $food_production_hour   += $building->$method();
        }
        if ($building->isa('KA::DB::Result::Building::SpacePort') and $building->effective_efficiency == 100) {
            $stats{max_berth} = $building->effective_level if ($building->effective_level > $stats{max_berth});
        }
        if ($building->isa('KA::DB::Result::Building::Ore::Ministry')) {
            my $platforms = KA->db->resultset('MiningPlatforms')->search({planet_id => $self->id});
            while (my $platform = $platforms->next) {
                foreach my $type (ORE_TYPES) {
                    my $method = $type.'_hour';
                    $stats{$method} += $platform->$method();
                }
            }
        }
        if ($building->isa('KA::DB::Result::Building::Trade')) {
            # Calculate the amount of waste to deduct based on the waste_chains
            my $waste_chains = KA->db->resultset('WasteChain')->search({planet_id => $self->id});
            while (my $waste_chain = $waste_chains->next) {
                my $percent = $waste_chain->percent_transferred;
                $percent = $percent > 100 ? 100 : $percent;
                $percent *= $building->effective_efficiency / 100;
                my $waste_hour = sprintf('%.0f',$waste_chain->waste_hour * $percent / 100);
                $stats{waste_hour} -= $waste_hour;
            }
            # calculate the resources being chained *from* this planet
            my $output_chains = $self->out_supply_chains->search({
                stalled     => 0,
            });
            while (my $out_chain = $output_chains->next) {
                my $percent = $out_chain->percent_transferred;
                $percent    = $percent > 100 ? 100 : $percent;
                $percent    *= $building->effective_efficiency / 100;

                my $resource_hour = sprintf('%.0f',$out_chain->resource_hour * $percent / 100);
                my $resource_name   = $self->resource_name($out_chain->resource_type);
                $stats{$resource_name} -= $resource_hour;
            }
        }
        if ($building->isa('KA::DB::Result::Building::Permanent::GasGiantPlatform')) {
            $gas_giant_platforms += int($building->effective_level * $building->effective_efficiency/100);
        }
        if ($building->isa('KA::DB::Result::Building::Permanent::TerraformingPlatform')) {
            $terraforming_platforms += int($building->effective_level * $building->effective_efficiency/100);
        }
        if ($building->isa('KA::DB::Result::Building::Permanent::PantheonOfHagness')) {
            $pantheon_of_hagness += int($building->effective_level * $building->effective_efficiency/100);
        }
        if ($building->isa('KA::DB::Result::Building::Module::StationCommand')) {
            $station_command += $building->effective_level;
        }
        if ($building->isa('KA::DB::Result::Building::Permanent::Fissure')) {
            # A fissure is controlled by maintenance equipment. The less efficient
            # the equipment, the more energy the Fissure will suck in.
            # Fissure affect on energy_hour is 1% per level subject to efficiency
            $fissure_percent += $building->effective_level * (100 - $building->effective_efficiency) / 100;
        }
    }
    # Energy reduced by Fissure action
    $stats{energy_hour} -= $stats{energy_hour} * $fissure_percent / 100;
    
    $stats{food_consumption_hour} = $food_consumption_hour;
    $stats{ore_consumption_hour} = $ore_consumption_hour;

    # active supply chains sent *to* this planet
    my $input_chains = $self->in_supply_chains->search({
        stalled     => 0,
    },{
        prefetch => 'building',
    });

    while (my $in_chain = $input_chains->next) {
        my $percent = $in_chain->percent_transferred;
        $percent = $percent > 100 ? 100 : $percent;
        $percent *= $in_chain->building->effective_efficiency / 100;
        my $resource_hour = sprintf('%.0f',$in_chain->resource_hour * $percent / 100);
        my $resource_name = $self->resource_name($in_chain->resource_type);
        $stats{$resource_name} += $resource_hour;
    }

    # local ore production
    foreach my $type (ORE_TYPES) {
        my $method = $type.'_hour';
        my $domestic_ore_hour = sprintf('%.0f',$self->$type * $ore_production_hour / $self->total_ore_concentration);
        $stats{$method} += $domestic_ore_hour;
    }
    $self->update;
    $self->discard_changes;
    
    # deal with negative amounts stored
    $self->water_stored(0) if $self->water_stored < 0;
    $self->energy_stored(0) if $self->energy_stored < 0;
    for my $type (FOOD_TYPES, ORE_TYPES) {
        my $stype = $type.'_stored';
        $self->$stype(0) if ($self->$stype < 0);
    }
    $self->update;
    $self->discard_changes;
    
    # deal with storage overages
    if ($self->ore_stored > $stats{ore_capacity}) {
        $self->spend_ore($self->ore_stored - $stats{ore_capacity});
    }
    if ($self->food_stored > $stats{food_capacity}) {
        $self->spend_food($self->food_stored - $stats{food_capacity}, 1);
    }
    if ($self->water_stored > $stats{water_capacity}) {
        $self->spend_water($self->water_stored - $stats{water_capacity});
    }
    if ($self->energy_stored > $stats{energy_capacity}) {
        $self->spend_energy($self->energy_stored - $stats{energy_capacity});
    }

    # deal with plot usage
    my $max_plots = $self->size + $pantheon_of_hagness;
    if ($self->isa('KA::DB::Result::Map::Body::Planet::GasGiant')) {
        $max_plots = min($gas_giant_platforms, $max_plots);
    }
    elsif ($self->isa('KA::DB::Result::Map::Body::Planet::Station')) {
        $max_plots = $stats{size} = $station_command * 3;
    }
    elsif ($self->isa('KA::DB::Result::Map::Body::Planet')) {
        if ($self->empire) {
            if ($self->orbit > $self->empire->max_orbit || $self->orbit < $self->empire->min_orbit) {
                $max_plots = min($terraforming_platforms, $max_plots);
            }
        }
    }
    # Adjust happiness_hour to maximum of 30 days from where body went negative. Different max for positive happiness.
    # If using spies to boost happiness rate, best rate can be a bit variable.
    if ($self->unhappy == 1) {
        my $happy = $self->happiness;
        my $max_rate =    150_000_000_000 * ((time < $self->empire->happiness_boost->epoch) ? 1.25 : 1);
        my $max_time =    720 / ((time < $self->empire->happiness_boost->epoch) ? 1.25 : 1);
        my $one_twenty =  120 / ((time < $self->empire->happiness_boost->epoch) ? 1.25 : 1);
        if ($happy < -1 * ($one_twenty * 150_000_000_000)) {
            my $div = 1;
            my $unhappy_time = DateTime->now->subtract_datetime_absolute($self->unhappy_date);
            my $unh_hours = $unhappy_time->seconds/(3600);
            if ($unh_hours < $max_time) {
                $div = $max_time - $unh_hours;
            }
            my $new_rate = int(abs($self->happiness)/$div);
            $max_rate = $new_rate if $new_rate > $max_rate;
        }
        $stats{happiness_hour} = $max_rate if ($stats{happiness_hour} > $max_rate);
    }

    $stats{plots_available} = $max_plots - $self->building_count;

    # Decrease happiness production if short on plots.
    if ($stats{plots_available} < 0) {
        my $plot_tax = int(50 * 1.62 ** (abs($stats{plots_available})-1));
        
        # Set max to at least -10k
        my $neg_hr = $self->happiness > 100_000 ? -1 * $self->happiness/10 : -10_000;
 
        if ( $stats{happiness_hour} < 0 and $stats{happiness_hour} > $neg_hr) {
            $stats{happiness_hour} = $neg_hr;
        }
        elsif ( ( $stats{happiness_hour} - $neg_hr) < $plot_tax) {
            $stats{happiness_hour} = $neg_hr;
        }
        else {
            $stats{happiness_hour} -= $plot_tax;
        }
        $stats{happiness_hour} = -100_000_000_000 if ($stats{happiness_hour} < -100_000_000_000);
    }
    $self->update;
    $self->discard_changes;
    $self->update(\%stats);
    return $self;
}

# NEWS
sub add_news {
    my ($self, $chance, $headline) = @_;

    if ($self->restrict_coverage) {
        my $network19 = $self->network19;
        if (defined $network19) {
            $chance += $network19->level * 2;
            $chance = $chance / $self->planetary_command->level; 
        }
    }
    if (randint(1,100) <= $chance) {
        $headline = sprintf $headline, @_ if @_;
        KA->db->resultset('KA::DB::Result::News')->new({
            date_posted => DateTime->now,
            zone        => $self->zone,
            headline    => $headline,
        })->insert;
        return 1;
    }
    return 0;
}


# RESOURCE MANGEMENT
sub tick {
    my ($self) = @_;
    
    # stop a double tick
    my $cache = KA->cache;
    if ($cache->get('ticking',$self->id)) {
        return undef;
    }
    else {
        $cache->set('ticking',$self->id, 1, 300);
    }
    
    my $now = DateTime->now;
    my $now_epoch = $now->epoch;
    my $dt_parser = KA->db->storage->datetime_parser;
    my %todo;
    my $i; # in case 2 things finish at exactly the same time

    # get building tasks
    if (not KA->config->get('beanstalk')) {
        my @buildings = grep {
            ($_->is_upgrading and $_->upgrade_ends->epoch <= $now_epoch) 
         or ($_->is_working and $_->work_ends->epoch <= $now_epoch)
        } @{$self->building_cache};

        foreach my $building (@buildings) {
            if ($building->is_upgrading && $building->upgrade_ends->epoch <= $now_epoch) {
                $todo{format_date($building->upgrade_ends).$i} = {
                    object  => $building,
                    type    => 'building upgraded',
                };
            }
            if ($building->is_working && $building->work_ends->epoch <= $now_epoch) {
                $todo{format_date($building->work_ends).$i} = {
                    object  => $building,
                    type    => 'building work complete',
                };
            }
            $i++;
        }
        # get fleet tasks
        my $fleets = KA->db->resultset('Fleet')->search({
            body_id         => $self->id,
            date_available  => { '<=' => $dt_parser->format_datetime($now) },
            task            => [qw(Travelling Building)],
        });
        while (my $fleet = $fleets->next ) {
            if ($fleet->task eq 'Travelling') {
                $todo{format_date($fleet->date_available).$i} = {
                    object  => $fleet,
                    type    => 'fleet arrives',
                };
            }
            elsif ($fleet->task eq 'Building') {
                $todo{format_date($fleet->date_available).$i} = {
                    object  => $fleet,
                    type    => 'fleet built',
                };
            }
            $i++;
        }
    }
    # synchronize completion of tasks
    foreach my $key (sort keys %todo) {
        my ($object, $job) = ($todo{$key}{object}, $todo{$key}{type});
        my $beanstalk = KA->config->get('beanstalk');

        if (not $beanstalk and $job eq 'fleet built') {
            $self->tick_to($object->date_available);
            $object->finish_construction;
        }
        elsif (not $beanstalk and $job eq 'fleet arrives') {
            $self->tick_to($object->date_available);
            $object->arrive;            
        }
        elsif (not $beanstalk and $job eq 'building work complete') {
            $self->tick_to($object->work_ends);
            $object->finish_work->update;
        }
        elsif (not $beanstalk and $job eq 'building upgraded') {
            $self->tick_to($object->upgrade_ends);
            $object->finish_upgrade;
        }
    }
    
    # check / clear boosts
    if ($self->boost_enabled) {
        my $empire = $self->empire;
        if ($empire) {
            my $still_enabled = 0;
            foreach my $resource (qw(energy water ore happiness food storage building spy_training)) {
                my $boost = $resource.'_boost';
                if ($now_epoch > $empire->$boost->epoch) {
                    $self->needs_recalc(1);
                }
                else {
                    $still_enabled = 1;
                }
            }
            unless ($still_enabled) {
                # avoid each planet sending the same boost expired message
                if (!$self->empire->check_for_repeat_message('boosts_expired')) {
                    $self->empire->send_predefined_message(
                        tags        => ['Alert'],
                        filename    => 'boosts_expired.txt',
                        repeat_check=> 'boosts_expired',
                    );
                }
                $self->boost_enabled(0);
            }
        }
    }

    $self->tick_to($now);

    # advance tutorial
    if ($self->empire and $self->empire->tutorial_stage ne 'turing') {
        KA::Tutorial->new(empire=>$self->empire)->finish;
    }
    # clear caches
    $self->clear_future_operating_resources;    
    $cache->delete('ticking', $self->id);
}

# Catch up on all ticks until now
sub tick_to {
    my ($self, $now) = @_;

    my $seconds  = $now->epoch - $self->last_tick->epoch;
    my $tick_rate = $seconds / 3600;
    $self->last_tick($now);
    
    #If we crossed zero happiness, either way, we need to recalc.
    if ($self->happiness < 0) {
        if ($self->unhappy) {
            # Nothing for now...
        }
        else {
            $self->needs_recalc(1);
            $self->unhappy(1);
            $self->unhappy_date($now);
        }
    }
    else {
        if ($self->unhappy) {
            $self->unhappy(0);
            $self->needs_recalc(1);
        }
        $self->needs_recalc(1) if ($self->propaganda_boost > 50);
    }
    if ($self->needs_recalc) {
        $self->recalc_stats;    
    }
    
    # Process excavator sites
    if ( my $arch = $self->archaeology) {
        if ($arch->effective_efficiency == 100 and $arch->effective_level > 0) {
            my $dig_sec = $now->epoch - $arch->last_check->epoch;
            if ($dig_sec >= 3600) {
                my $dig_hours = int($dig_sec/3600);
                my $new_ld = $arch->last_check->add( seconds => ($dig_hours * 3600));
                $dig_hours = 3 if $dig_hours > 3;
                for (1..$dig_hours) {
                    $arch->run_excavators;
                }
                $arch->last_check($new_ld);
                $arch->update;
            }
        }
        else {
            $arch->last_check($now);
        }
    }

    # happiness
    $self->add_happiness(sprintf('%.0f', $self->happiness_hour * $tick_rate));
    
    # waste
    if ($self->waste_hour < 0 ) { # if it gets negative, spend out of storage
        $self->spend_waste(sprintf('%.0f',abs($self->waste_hour) * $tick_rate));
    }
    else {
        $self->add_waste(sprintf('%.0f', $self->waste_hour * $tick_rate));
    }
    
    # energy
    if ($self->energy_hour < 0 ) { # if it gets negative, spend out of storage
        $self->spend_energy(sprintf('%.0f',abs($self->energy_hour) * $tick_rate));
    }
    else {
        $self->add_energy(sprintf('%.0f', $self->energy_hour * $tick_rate));
    }
    
    # water
    if ($self->water_hour < 0 ) { # if it gets negative, spend out of storage
        $self->spend_water(sprintf('%.0f',abs($self->water_hour) * $tick_rate));
    }
    else {
        $self->add_water(sprintf('%.0f', $self->water_hour * $tick_rate));
    }
    
    # ore
    my %ore;
    my $ore_produced   = 0;
    foreach my $type (ORE_TYPES) {
        my $method = $type.'_hour';
        $ore{$type} = sprintf('%.0f', $self->$method() * $tick_rate);
        if ($ore{$type} > 0) {
            $ore_produced += $ore{$type};
        }
    }
    my $ore_consumed = sprintf('%.0f', $self->ore_consumption_hour * $tick_rate);
    if ($ore_produced > 0 and $ore_produced >= $ore_consumed) {
        # then consumption comes out of production
        foreach my $type (ORE_TYPES) {
            if ($ore{$type} > 0) {
                $ore{$type} -= sprintf('%.0f', $ore{$type} * $ore_consumed / $ore_produced);
            }
        }
    }
    else {
        # We are consuming more than we are producing
        # The difference between consumed and produced comes out of storage
        $ore_consumed -= $ore_produced;
        if ($ore_consumed > 0) {
            my $total_ore = $self->ore_stored;
            if ($total_ore > 0) {
                my $deduct_ratio = $ore_consumed / $total_ore;
                $deduct_ratio = 1 if $deduct_ratio > 1;
                foreach my $type (ORE_TYPES) {
                    my $type_stored = $self->type_stored($type);
                    $ore{$type} = 0 if $ore{$type} > 0;
                    my $to_deduct = sprintf('%.0f', $type_stored * $deduct_ratio);
                    $self->spend_ore_type($type, $to_deduct);
                    $ore_consumed -= $to_deduct;
                }

            }
            # if we *still* have ore to consume when we have nothing then we are in trouble!
            if ($ore_consumed > 20) {
                # deduct an arbitrary ore-stuff, but allow for rounding (hence the '20')
                $self->spend_ore_type('gold', $ore_consumed, 'complain');
            }
        }
    }
    # Now deal with remaining individual ore stuffs
    foreach my $type (ORE_TYPES) {
        if ($ore{$type} > 0) {
            $self->add_ore_type($type, $ore{$type});
        }
        elsif ($ore{$type} < 0) {
            $self->spend_ore_type($type, abs($ore{$type}));
        }
    }


    # food
    my %food;
    my $food_produced   = 0;
    foreach my $type (FOOD_TYPES) {
        my $production_hour_method = $type.'_production_hour';
        $food{$type} = sprintf('%.0f', $self->$production_hour_method() * $tick_rate);
        if ($food{$type} > 0) {
            $food_produced += $food{$type};
        }
    }
    my $food_consumed = sprintf('%.0f', $self->food_consumption_hour * $tick_rate);
    if ($food_produced > 0 and $food_produced >= $food_consumed) {
        # Then consumption just comes out of production
        foreach my $type (FOOD_TYPES) {
            if ($food{$type} > 0) {
                $food{$type} -= sprintf('%.0f', $food{$type} * $food_consumed / $food_produced);
            }
        }
    }
    else {
        # We are consuming more than we are producing
        # The difference between consumed and produced comes out of storage
        $food_consumed -= $food_produced;
        if ($food_consumed > 0) {
            my $total_food = $self->food_stored;
            if ($total_food > 0) {
                # 
                my $deduct_ratio = $food_consumed / $total_food;
                $deduct_ratio = 1 if $deduct_ratio > 1;
                foreach my $type (FOOD_TYPES) {
                    my $type_stored = $self->type_stored($type);
                    $food{$type} = 0 if $food{$type} > 0;
                    my $to_deduct = sprintf('%.0f', $type_stored * $deduct_ratio);
                    $self->spend_food_type($type, $to_deduct);
                    $food_consumed -= $to_deduct;
                }
            }
            # if we *still* have food to consume when we have nothing then we are in trouble!
            if ($food_consumed > 20) {
                # deduct an arbitrary food-stuff, but allow for rounding errors (hence the 20)
                $self->spend_food_type('algae', $food_consumed, 'complain');
            }
        }
    }
    # Now deal with remaining individual food stuffs
    foreach my $type (FOOD_TYPES) {
        if ($food{$type} > 0) {
            $self->add_food_type($type, $food{$type});
        }
        elsif ($food{$type} < 0) {
            $self->spend_food_type($type, abs($food{$type}));
        }
    }

    # deal with negative amounts stored
    # and stall/unstall any supply-chains
    my @supply_chains = $self->out_supply_chains->all;

    if ($self->water_stored <= 0) {
        $self->water_stored(0);
        $self->toggle_supply_chain(\@supply_chains, 'water', 1)
    }
    else {
        $self->toggle_supply_chain(\@supply_chains, 'water', 0);
    }
    if ($self->energy_stored <= 0) {
        $self->energy_stored(0);
        $self->toggle_supply_chain(\@supply_chains, 'energy', 1);
    }
    else {
        $self->toggle_supply_chain(\@supply_chains, 'energy', 0);
    }

    for my $type (FOOD_TYPES, ORE_TYPES) {
        if ($self->type_stored($type) <= 0) {
            $self->type_stored($type, 0);
            $self->toggle_supply_chain(\@supply_chains, $type, 1);
        }
        else {
            $self->toggle_supply_chain(\@supply_chains, $type, 0);
        }
    }
    if ($self->isa('KA::DB::Result::Map::Body::Planet::Station')) {
        my @buildings = grep {
            $_->efficiency == 0
        } @{$self->building_cache};
        foreach my $building (@buildings) {
            $building->downgrade;
        }
    }
    $self->update;
}

# Change the state of a supply chain (stalled/not-stalled)
sub toggle_supply_chain {
    my ($self, $chains_ref, $resource, $stalled) = @_;

    my @chains = grep {$_->stalled != $stalled and $_->resource_type eq $resource } @$chains_ref;

    foreach my $chain (@chains) {
        $chain->stalled($stalled);
        $chain->update;
        $chain->target->needs_recalc(1);
        $chain->target->update;
        $self->needs_recalc(1);
        $self->update;
        my $empire = $self->empire;
        if ($stalled
            and defined $empire 
            and not $empire->check_for_repeat_message('supply_stalled'.$chain->id)) {
            $empire->send_predefined_message(
                filename    => 'stalled_chain.txt',
                params      => [$self->id, $self->name, $chain->resource_type],
                repeat_check=> 'supply_stalled'.$chain->id,
                tags        => ['Complaint','Alert'],
            );
        }
    }
}

# Return the amount of a resource type stored
# or modify the amount stored if '$value' is specified
sub type_stored {
    my ($self, $type, $value) = @_;

    my $stored_method = $type.'_stored';
    if (defined $value) {
        $self->$stored_method($value);
    }
    return $self->$stored_method;
}

# Do we have enough of a resource to spend?
sub can_spend_type {
    my ($self, $type, $value) = @_;

    my $stored = $type.'_stored';
    if ($self->$stored < $value) {
        confess [1009, "You don't have enough $type in storage."];
    }
    return 1;
}

# Spend $value amount of a resource $type
sub spend_type {
    my ($self, $type, $value) = @_;

    my $method = 'spend_'.$type;
    $self->$method($value);
    return $self;
}

# Can we add $value more of a $type of resource?
sub can_add_type {
    my ($self, $type, $value) = @_;

    if ($type ~~ [ORE_TYPES]) {
        $type = 'ore';
    }
    if ($type ~~ [FOOD_TYPES]) {
        $type = 'food';
    }
    my $capacity = $type.'_capacity';
    my $stored = $type.'_stored';
    my $available_storage = $self->$capacity - $self->$stored;
    if ($available_storage < $value) {
        confess [1009, "You don't have enough available storage."];
    }
    return 1;
}

# Add $value amound of a resource $type
sub add_type {
    my ($self, $type, $value) = @_;

    my $method = 'add_'.$type;
    eval {
        $self->can_add_type($type, $value);
    };
    if ($@) {
        my $empire = $self->empire;
        if (defined $empire 
            && !$empire->skip_resource_warnings 
            && !$empire->check_for_repeat_message('complaint_overflow'.$self->id)) {
            $empire->send_predefined_message(
                filename        => 'complaint_overflow.txt',
                params          => [$type, $self->id, $self->name],
                repeat_check    => 'complaint_overflow'.$self->id,
                tags            => ['Complaint','Alert'],
            );
        }
    }
    $self->$method($value);
    return $self;
}

# How much ore is stored?
sub ore_stored {
    my ($self) = @_;
    my $tally = 0;
    foreach my $ore (ORE_TYPES) {
        $tally += $self->type_stored($ore);
    }
    return $tally;
}

# add a random ore type
sub add_ore {
    my ($self, $value) = @_;
    foreach my $type (shuffle ORE_TYPES) {
        next if $self->$type < 100; 
        my $add_method = 'add_'.$type;
        $self->$add_method($value);
        last;
    }
    return $self;
}

# add a specific $type of ore
sub add_ore_type {
    my ($self, $type, $amount_requested) = @_;

    my $available_storage = $self->ore_capacity - $self->ore_stored;
    $available_storage = 0 if ($available_storage < 0);
    my $amount_to_add = ($amount_requested <= $available_storage) ? $amount_requested : $available_storage;
    $self->type_stored($type, $self->type_stored($type) + $amount_to_add );
    return $self;
}

# spend a specific $type of ore
sub spend_ore_type {
    my ($self, $type, $amount_spent, $complain) = @_;
    my $amount_stored = $self->type_stored($type);
    if ($amount_spent > $amount_stored && $amount_spent > 0) {
        my $difference = $amount_spent - $amount_stored;
        $self->spend_happiness($difference);
        $self->type_stored($type, 0);

        if ($complain &&
            ($difference * 100) / $amount_spent > 5) {
           
            $self->complain_about_lack_of_resources('ore');
        }
    }
    else {
        $self->type_stored($type, $amount_stored - $amount_spent );
    }
    return $self;
}

# Created methods for ore, e.g. 'add_magnetite', 'spend_magnetite'
for my $ore (ORE_TYPES) {
    __PACKAGE__->meta->add_method("add_$ore" => sub {
        my ($self, $value) = @_;
        return $self->add_ore_type($ore, $value);
    });
    __PACKAGE__->meta->add_method("spend_$ore" => sub {
        my ($self, $value) = @_;
        return $self->spend_ore_type($ore, $value);
    });
}

# Spend proportionally from all ore
sub spend_ore {
    my ($self, $ore_consumed) = @_;

    # take inventory
    my $ore_stored;
    foreach my $type (ORE_TYPES) {
        $ore_stored += $self->type_stored($type);
    }

    # spend proportionally and save
    if ($ore_stored) {
        foreach my $type (ORE_TYPES) {
            $self->spend_ore_type($type, sprintf('%.0f', ($ore_consumed * $self->type_stored($type)) / $ore_stored),'complain');
        }
    }
    return $self;
}

sub ore_hour {
    my ($self) = @_;
    my $tally = 0;
    foreach my $ore (ORE_TYPES) {
        my $method = $ore."_hour";
        $tally += $self->$method;
    }
    $tally -= $self->ore_consumption_hour;
    return $tally;
}

# determine the total food production per hour
sub food_hour {
    my ($self) = @_;
    my $tally = 0;
    foreach my $food (FOOD_TYPES) {
        my $method = $food."_production_hour";
        $tally += $self->$method;
    }
    $tally -= $self->food_consumption_hour;
    return $tally;
}

# determine the total food stored
sub food_stored {
    my ($self) = @_;
    my $tally = 0;
    foreach my $food (FOOD_TYPES) {
        $tally += $self->type_stored($food);
    }
    return $tally;
}

# add to a specific $type of food stored
sub add_food_type {
    my ($self, $type, $amount_requested) = @_;

    my $available_storage = $self->food_capacity - $self->food_stored;
    $available_storage = 0 if ($available_storage < 0);
    my $amount_to_add = ($amount_requested <= $available_storage) ? $amount_requested : $available_storage;
    $self->type_stored($type, $self->type_stored($type) + $amount_to_add );
    return $self;
}

# spend from a specific $type of food
sub spend_food_type {
    my ($self, $type, $amount_spent, $complain) = @_;
    my $amount_stored = $self->type_stored($type);
    if ($amount_spent > 0 && $amount_spent > $amount_stored) {
        my $difference = $amount_spent - $amount_stored;
        $self->spend_happiness($difference);
        $self->type_stored($type, 0);

        # Complain about lack of resources if required but avoid rounding errors
        if ($complain &&
            ($difference * 100) / $amount_spent > 5) {

            $self->complain_about_lack_of_resources('food');
        }
    }
    else {
        $self->type_stored($type, $amount_stored - $amount_spent );
    }
    return $self;
}

# add methods for all food types, such as 'add_algae' and 'spend_algae'
for my $food (FOOD_TYPES) {
    __PACKAGE__->meta->add_method("add_$food" => sub {
        my ($self, $value) = @_;
        return $self->add_food_type($food, $value);
    });
    __PACKAGE__->meta->add_method("spend_$food" => sub {
        my ($self, $value) = @_;
        return $self->spend_food_type($food, $value);
    });
}

# Spend proportionally from all foods
sub spend_food {
    my ($self, $food_consumed, $loss) = @_;
    
    $loss = 0 unless defined($loss);
    # take inventory
    my $food_stored;
    my $food_type_count = 0;
    foreach my $type (FOOD_TYPES) {
        my $stored = $self->type_stored($type);
        $food_stored += $stored;
        $food_type_count++ if ($stored);
    }
    
    # spend proportionally and save
    if ($food_stored) {
        foreach my $type (FOOD_TYPES) {
            # We 'complain' about lack of food if we are spending out of generic food
            # we don't complain about specific foods, because we can always substitute.
            $self->spend_food_type($type, sprintf('%.0f', ($food_consumed * $self->type_stored($type)) / $food_stored),'complain');
        }
    }
    
    # adjust happiness based on food diversity
    unless ($loss or $self->isa('KA::DB::Result::Map::Body::Planet::Station')) {
        if ($food_type_count > 3) {
            $self->add_happiness($food_consumed);
        }
        elsif ($food_type_count < 3) {
            $self->spend_happiness($food_consumed);
            my $empire = $self->empire;
            if (!$empire->skip_resource_warnings && $empire->university_level > 2 && !$empire->check_for_repeat_message('complaint_food_diversity'.$self->id)) {
                $empire->send_predefined_message(
                    filename    => 'complaint_food_diversity.txt',
                    params      => [$self->id, $self->name],
                    repeat_check=> 'complaint_food_diversity'.$self->id,
                    tags        => ['Complaint','Alert'],
                );
            }
        }
    }
    return $self;
}

# add to energy stored
sub add_energy {
    my ($self, $value) = @_;

    my $store = $self->energy_stored + $value;
    my $storage = $self->energy_capacity;
    $self->energy_stored( ($store < $storage) ? $store : $storage );
    return $self;
}

# spend from energy reserve
sub spend_energy {
    my ($self, $amount_spent) = @_;

    my $amount_stored = $self->energy_stored;
    if ($amount_spent > $amount_stored) {
        $self->spend_happiness($amount_spent - $amount_stored);
        $self->energy_stored(0);
        $self->complain_about_lack_of_resources('energy');
    }
    else {
        $self->energy_stored( $amount_stored - $amount_spent );
    }
    return $self;
}

# add to water stored
sub add_water {
    my ($self, $value) = @_;

    my $store = $self->water_stored + $value;
    my $storage = $self->water_capacity;
    $self->water_stored( ($store < $storage) ? $store : $storage );
    return $self;
}

# spend from water reserve
sub spend_water {
    my ($self, $amount_spent) = @_;

    my $amount_stored = $self->water_stored;
    if ($amount_spent > $amount_stored) {
        $self->spend_happiness($amount_spent - $amount_stored);
        $self->water_stored(0);
        $self->complain_about_lack_of_resources('water');
    }
    else {
        $self->water_stored( $amount_stored - $amount_spent );
    }
    return $self;
}

# increase the amount of happiness
sub add_happiness {
    my ($self, $value) = @_;

    my $new = $self->happiness + $value;
    if ($new < 0 && $self->empire->is_isolationist) {
        $new = 0;
    }
    $self->happiness( $new );
    return $self;
}

# decrease the amount of happiness
sub spend_happiness {
    my ($self, $value) = @_;
    $self->tick;
    
    my $new = $self->happiness - $value;
    my $empire = $self->empire;
    if ($empire and $new < 0) {
        if ($empire->is_isolationist) {
            $new = 0;
        }
        elsif (!$empire->skip_happiness_warnings && !$empire->check_for_repeat_message('complaint_unhappy'.$self->id)) {
            $empire->send_predefined_message(
                filename    => 'complaint_unhappy.txt',
                params      => [$self->id, $self->name],
                repeat_check=> 'complaint_unhappy'.$self->id,
                tags        => ['Complaint','Alert'],
            );
        }
    }
    $self->happiness( $new );
    return $self;
}

# add to the amount of waste stored
sub add_waste {
    my ($self, $value) = @_;

    my $store = $self->waste_stored + $value;
    my $storage = $self->waste_capacity;
    if ($store < $storage) {
        $self->waste_stored( $store );
    }
    else {
        my $empire = $self->empire;
        return $self unless $empire;
        $self->waste_stored( $storage );
        $self->spend_happiness( $store - $storage ); # pollution
        if (!$empire->skip_pollution_warnings && $empire->university_level > 2 && !$empire->check_for_repeat_message('complaint_pollution'.$self->id)) {
            $empire->send_predefined_message(
                filename    => 'complaint_pollution.txt',
                params      => [$self->id, $self->name],
                repeat_check=> 'complaint_pollution'.$self->id,
                tags        => ['Complaint','Alert'],
            );
        }
    }
    return $self;
}

# reduce the amount of waste
# if waste goes negative, strip waste using buildings
sub spend_waste {
    my ($self, $value) = @_;
    if ($self->waste_stored >= $value) {
        $self->waste_stored( $self->waste_stored - $value );
    }
    else { # if they run out of waste in storage, then the citizens start bitching
        $self->spend_happiness($value - $self->waste_stored);
        $self->waste_stored(0);
        my $empire = $self->empire;
        if (!KA->cache->get('lack_of_waste',$self->id)) {
            my $building_name;
            KA->cache->set('lack_of_waste',$self->id, 1, 60 * 60 * 2);
            foreach my $class (qw(KA::DB::Result::Building::Energy::Waste KA::DB::Result::Building::Waste::Treatment KA::DB::Result::Building::Waste::Digester KA::DB::Result::Building::Water::Reclamation KA::DB::Result::Building::Waste::Exchanger)) {
                my ($building) = grep {$_->efficiency > 0} $self->get_buildings_of_class($class);
                if (defined $building) {
                    $building_name = $building->name;
                    $building->spend_efficiency(25)->update;
                    last;
                }
            }
            if ($building_name && !$empire->skip_resource_warnings && !$empire->check_for_repeat_message('complaint_lack_of_waste'.$self->id)) {
                $empire->send_predefined_message(
                    filename    => 'complaint_lack_of_waste.txt',
                    params      => [$building_name, $self->id, $self->name, $building_name],
                    repeat_check=> 'complaint_lack_of_waste'.$self->id,
                    tags        => ['Complaint','Alert'],
                );
            }
        }
    }
    return $self;
}

# the title says it all
sub complain_about_lack_of_resources {
    my ($self, $resource) = @_;
    my $empire = $self->empire;
    # if they run out of resources in storage, then the citizens start bitching
    if (!KA->cache->get('lack_of_'.$resource,$self->id)) {
        my $building_name;
        KA->cache->set('lack_of_'.$resource,$self->id, 1, 60 * 60 * 2);
        if ($self->isa('KA::DB::Result::Map::Body::Planet::Station')) {
            foreach my $building ( sort {
                                          $b->effective_level <=> $a->effective_level ||
                                          $b->efficiency <=> $a->efficiency ||
                                          rand() <=> rand()
                                        }
                                   grep {
                                       $_->class ne 'KA::DB::Result::Building::DeployedBleeder' and
                                       $_->class ne 'KA::DB::Result::Building::Permanent::Crater'
                                   }
                                   @{$self->building_cache} ) {
                if ($building->class eq 'KA::DB::Result::Building::Module::Parliament' || $building->class eq 'KA::DB::Result::Building::Module::StationCommand') {
                    my $others = grep {
                        $_->class ne 'KA::DB::Result::Building::Module::Parliament' and
                        $_->class ne 'KA::DB::Result::Building::Module::StationCommand'
                    } @{$self->building_cache};
                    if ($others) {
                        # If there are other buildings, divert power from them to keep Parliament and Station Command running as long as possible
                        next;
                    }
                    else {
                        my $par = $self->get_building_of_class('KA::DB::Result::Building::Module::Parliament');
                        my $sc = $self->get_building_of_class('KA::DB::Result::Building::Module::StationCommand');
                        if ($sc && $par) {
                            if ($sc->level == $par->level) {
                                if ($sc->level == 1 && $sc->efficiency <= 50 && $par->efficiency <= 50) {
                                    # They go out together with a big bang
                                    $building_name = $par->name;
                                    eval { $sc->spend_efficiency(60) };
                                    eval { $par->spend_efficiency(60) };
                                    last;
                                }
                                elsif ($sc->efficiency <= $par->efficiency) {
                                    $building_name = $par->name;
                                    eval { $par->spend_efficiency(50)->update };
                                    last;
                                }
                                else {
                                    $building_name = $sc->name;
                                    eval {$sc->spend_efficiency(50)->update };
                                    last;
                                }
                            }
                            elsif ($sc->level < $par->level) {
                                $building_name = $par->name;
                                eval {$par->spend_efficiency(50)->update };
                                last;
                            }
                            else {
                                $building_name = $sc->name;
                                eval {$sc->spend_efficiency(50)->update };
                                last;
                            }
                        }
                        elsif ($sc) {
                            $building_name = $sc->name;
                            eval { $sc->spend_efficiency(50)->update };
                            last;
                        }
                        elsif ($par) {
                            $building_name = $par->name;
                            eval { $par->spend_efficiency(50)->update };
                            last;
                        }
                    }
                }
                else {
                    next if ($building->class eq 'KA::DB::Result::Building::Permanent::Crater' or
                             $building->class eq 'KA::DB::Result::Building::DeployedBleeder');
                    $building_name = $building->name;
                    eval { $building->spend_efficiency(50)->update };
                    last;
                }
            }
        }
        else {
             my $class;
            foreach my $rpcclass (shuffle (BUILDABLE_CLASSES)) {
                $class = $rpcclass->model_class;
                next unless ('Infrastructure' ~~ [$class->build_tags]);
            }
            my ($building) = grep {$_->efficiency > 0} $self->get_buildings_of_class($class);
            if (defined $building) {
                $building_name = $building->name;
                $building->spend_efficiency(25)->update;
            }
        }
        if ($building_name && !$empire->skip_resource_warnings && !$empire->check_for_repeat_message('lack_of_'.$resource.$self->id)) {
            $empire->send_predefined_message(
                filename    => 'complaint_lack_of_'.$resource.'.txt',
                params      => [$self->id, $self->name, $building_name],
                repeat_check=> 'complaint_lack_of_'.$resource.$self->id,
                tags        => ['Complaint','Alert'],
            );
        }
    }
}

no Moose;
__PACKAGE__->meta->make_immutable(inline_constructor => 0);
