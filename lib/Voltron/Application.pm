package Voltron::Application;
use 5.010;

#ABSTRACT: A role that turns objects into Voltron applications

use MooseX::Declare;

role Voltron::Application with POEx::ProxySession::Client
{
    use Voltron::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Socket;

    has version =>
    (
        is      => 'ro',
        isa     => Num,
    );

    has min_participant_version =>
    (
        is      => 'ro',
        isa     => Num,
    );

    has requires =>
    (
        is      => 'ro',
        isa     => MethodHash,
    );

    has connection_ids =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[WheelID],
        default     => sub { {} },
        lazy        => 1,
        provides    => 
        {
            exists      => 'has_connection',
            set         => 'set_connection',
            get         => 'get_connection',
            delete      => 'dete_connection',
            count       => 'count_connections',
            values      => 'all_connections',
        }
    );
    
    method run(ArrayRef[ServerConfiguration] :$server_configs)
    {
        foreach my $config (@$server_configs)
        {
            $self->yield
            (
                'connect'
                remote_address  => $config->{remote_address},
                remote_port     => $config->{remote_port},
                return_event    => 'publish_self'
            );

            $self->set_pending
            (
                'VOLTRON'.$config->{remote_address}.$config->{remote_port},
                {
                    return_session  => $config->{return_session} // $self->poe->sender->ID,
                    return_event    => $config->{return_event},
                }
            );
        }
    }

    method publish_self(WheelID :$connection_id, Str :$remote_address, Int :$remote_port)
    {
        
    }
}

1;
__END__
