package KA::DB::Result::Ships::Snark;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'KA::DB::Result::Ships';

use constant prereq                 => [ { class=> 'KA::DB::Result::Building::MunitionsLab',  level => 5 } ];
use constant base_food_cost         => 18000;
use constant base_water_cost        => 46800;
use constant base_energy_cost       => 145000;
use constant base_ore_cost          => 195030;
use constant base_time_cost         => 60 * 60 * 16;
use constant base_waste_cost        => 39600;
use constant base_speed             => 1000;
use constant base_stealth           => 2400;
use constant base_combat            => 2000;
use constant base_hold_size         => 0;
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
