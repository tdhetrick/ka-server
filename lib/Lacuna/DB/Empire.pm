package Lacuna::DB::Empire;

use Moose;
extends 'SimpleDB::Class::Item';
use DateTime;
use Lacuna::Util;
use Digest::SHA;
use Lacuna::DB::Building::PlanetaryCommand;

__PACKAGE__->set_domain_name('empire');
__PACKAGE__->add_attributes(
    name            => { isa => 'Str', 
        trigger => sub {
            my ($self, $new, $old) = @_;
            $self->name_cname(Lacuna::Util::cname($new));
        },
    },
    name_cname          => { isa => 'Str' },
    date_created        => { isa => 'DateTime' },
    description         => { isa => 'Str' },
    home_planet_id      => { isa => 'Str' },
    status_message      => { isa => 'Str' },
    friends_and_foes    => { isa => 'Str' },
    password            => { isa => 'Str' },
    last_login          => { isa => 'DateTime' },
    species_id          => { isa => 'Str' },
    essentia            => { isa => 'Int', default=>0 },
    points              => { isa => 'Int', default=>0 },
    rank                => { isa => 'Int', default=>0 }, # just where it is stored, but will come out of date quickly
    probed_stars        => { isa => 'ArrayRefOfStr' },
    university_level    => { isa => 'Int', default=>0 },
);

# achievements
# personal confederacies

__PACKAGE__->belongs_to('species', 'Lacuna::DB::Species', 'species_id');
__PACKAGE__->has_many('sessions', 'Lacuna::DB::Session', 'empire_id');
__PACKAGE__->has_many('alliance', 'Lacuna::DB::AllianceMember', 'alliance_id');
__PACKAGE__->has_many('planets', 'Lacuna::DB::Body::Planet', 'empire_id');
__PACKAGE__->has_many('sent_messages', 'Lacuna::DB::Message', 'from_id');
__PACKAGE__->has_many('received_messages', 'Lacuna::DB::Message', 'to_id');
__PACKAGE__->has_many('build_queues', 'Lacuna::DB::BuildQueue', 'empire_id');

sub spend_essentia {
    my ($self, $value) = @_;
    $self->essentia( $self->essentia - $value );
}

sub add_essentia {
    my ($self, $value) = @_;
    $self->essentia( $self->essentia + $value );
}

sub home_planet {
    my ($self) = @_;
    $self->simpledb->domain('Lacuna::DB::Body::Planet')->find($self->home_planet_id);
}

sub get_status {
    my ($self) = @_;
    my $planet_rs = $self->planets;
    my %planets;
    my $happiness = 0;
    my $happiness_hour = 0;
    while (my $planet = $planet_rs->next) {
        $happiness += $planet->happiness;
        $happiness_hour += $planet->happiness_hour;
    }
    $self = $self->simpledb->domain('empire')->find($self->id); # refetch because it's likely changed
    my $status = {
        server  => {
            "time" => DateTime::Format::Strptime::strftime('%d %m %Y %H:%M:%S %z',DateTime->now),
        },
        empire  => {
            full_status_update_required => 0,
            happiness                   => $happiness,
            happiness_hour              => $happiness_hour,
            essentia                    => $self->essentia,
            has_new_messages            => $self->get_new_message_count,
        },
    };
    return $status;
}

sub get_new_message_count {
    my $self = shift;
    return $self->simpledb->domain('message')->count(where => { to_id=>$self->id, has_archived => ['!=', 1], has_read => ['!=', 1]});
}

sub get_full_status {
    my ($self) = @_;
    my $planet_rs = $self->planets;
    my %planets;
    my $happiness = 0;
    my $happiness_hour = 0;
    while (my $planet = $planet_rs->next) {
        $planet = $planet->tick;
        $planets{$planet->id} = $planet->get_extended_status;
        $happiness += $planet->happiness;
        $happiness_hour += $planet->happiness_hour;
    }
    my $status = {
        server  => {
            "time" => DateTime::Format::Strptime::strftime('%d %m %Y %H:%M:%S %z',DateTime->now),
        },
        empire  => {
            happiness           => $happiness,
            happiness_hour      => $happiness_hour,
            name                => $self->name,
            id                  => $self->id,
            essentia            => $self->essentia,
            has_new_messages    => $self->get_new_message_count,
            home_planet_id      => $self->home_planet_id,
            planets             => \%planets,
        },
    };
    return $status;
}

sub start_session {
    my $self = shift;
    my $session = $self->simpledb->domain('session')->insert({
        empire_id       => $self->id,
        date_created    => DateTime->now,
        expires         => DateTime->now->add(hours=>2), 
    });
    $self->last_login(DateTime->now);
    $self->put;
    return $session;
}

sub is_password_valid {
    my ($self, $password) = @_;
    return ($self->password eq $self->encrypt_password($password)) ? 1 : 0;
}
sub encrypt_password {
    my ($self, $password) = @_;
    return Digest::SHA::sha256_base64($password);
}


sub found {
    my ($class, $simpledb, $home_planet, $species, $account, $empire_id) = @_;
 
    my %options;
    if ($empire_id) {
        $options{id} = $empire_id;
    }
    my $self = $simpledb->domain('empire')->insert({
        name                => $account->{name},
        date_created        => DateTime->now,
        password            => $class->encrypt_password($account->{password}),
        species_id          => $species->id,
        home_planet_id      => $home_planet->id,
        probed_stars        => [$home_planet->star_id],
    }, %options);

    $self->send_welcome_message;

    $self->add_essentia(100); # REMOVE BEFORE LAUNCH
    
    # found colony
    $home_planet->found_colony($self->id);
    
    return $self;
}

sub send_welcome_message {
    my ($self) = @_;
    open my $file, "<", '/data/Lacuna-Server/var/messages/welcome.txt';
    my $message;
    {
        local $/;
        $message = <$file>;
    }
    close $file;
    Lacuna::DB::Message->send(
        simpledb    => $self->simpledb,
        from        => $self->lacuna_expanse_corp,
        to          => $self,
        subject     => 'Welcome',
        body        => sprintf($message, $self->name),
    );
}

sub lacuna_expanse_corp {
    my $self = shift;
    return $self->simpledb->domain('empire')->find('lacuna_expanse_corp');
}

before 'delete' => sub {
    my ($self) = @_;
    my $db = $self->simpledb;
    $self->sent_messages->delete;
    $self->received_messages->delete;
    $self->build_queues->delete;
    my $planets = $self->planets;
    while ( my $planet = $planets->next ) {
        $planet->sanitize;
    }
    #$self->alliance->remove($self);
    if ($self->species_id ne 'human_species') {
        $self->species->delete;
    }
    $self->sessions->delete;
};

no Moose;
__PACKAGE__->meta->make_immutable;
