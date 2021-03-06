package KA::DB::Result::Ships::Placebo4;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'KA::DB::Result::Ships';

use constant prereq                 => [{ class=> 'KA::DB::Result::Building::CloakingLab',  level => 20 }];
use constant base_food_cost         => 2000;
use constant base_water_cost        => 2000;
use constant base_energy_cost       => 7000;
use constant base_ore_cost          => 7000;
use constant base_time_cost         => 3600;
use constant base_waste_cost        => 700;
use constant base_speed             => 2000;
use constant base_combat            => 0;
use constant base_stealth           => 7000;
use constant base_hold_size         => 0;
use constant build_tags             => [qw(War)];
use constant type_formatted         => 'Placebo IV';

with "KA::Role::Ship::Send::NeutralArea";
with "KA::Role::Ship::Send::Planet";
with "KA::Role::Ship::Send::Inhabited";
with "KA::Role::Ship::Send::NotIsolationist";
with "KA::Role::Ship::Send::IsHostile";
with "KA::Role::Ship::Arrive::Scuttle";

no Moose;
__PACKAGE__->meta->make_immutable(inline_constructor => 0);
