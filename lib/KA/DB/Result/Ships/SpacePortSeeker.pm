package KA::DB::Result::Ships::SpacePortSeeker;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'KA::DB::Result::Ships';

use constant prereq                 => [ { class=> 'KA::DB::Result::Building::MunitionsLab',  level => 15 } ];
use constant base_food_cost         => 20000;
use constant base_water_cost        => 50000;
use constant base_energy_cost       => 160000;
use constant base_ore_cost          => 200000;
use constant base_time_cost         => 58500;
use constant base_waste_cost        => 40000;
use constant base_speed             => 1000;
use constant base_combat            => 3000;
use constant base_stealth           => 2700;
use constant target_building        => ['KA::DB::Result::Building::SpacePort'];
use constant build_tags             => ['War'];

with "KA::Role::Ship::Send::NeutralArea";
with "KA::Role::Ship::Send::Planet";
with "KA::Role::Ship::Send::Inhabited";
with "KA::Role::Ship::Send::NotIsolationist";
with "KA::Role::Ship::Send::IsHostile";
with "KA::Role::Ship::Arrive::TriggerDefense";
with "KA::Role::Ship::Arrive::DamageBuilding";

no Moose;
__PACKAGE__->meta->make_immutable(inline_constructor => 0);
