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

    has application_name => 
    (
        is      => 'ro',
        isa     => Str,
    );
    
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
    
    has provides =>
    (
        is              => 'ro',
        isa             => MethodHash,
        lazy_builder    => 1,
    );

    has connections =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[ServerConnectionInfo],
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


    method _build_provides
    {
        my @methods;
        foreach my $method ($self->meta->get_all_methods)
        {
            if($method->isa('Class::MOP::Method::Wrapped'))
            {
                my $orig = $method->get_original_method;
                if(!$orig->meta->isa('Moose::Meta::Class') || !$orig->meta->does_role(VoltronEvent))
                {
                    next;
                }
                
                $method = $orig;
            }
            elsif(!$method->meta->isa('Moose::Meta::Class') || !$method->meta->does_role(VoltronEvent))
            {
                next;
            }

            push(@methods, $method);
        }

        return { map { $_->name, $_->signature } @methods };
    }

    around handle_inbound_data(VoltronMessage $data, WheelID $id) is Event
    {
    }

    
    method run(ArrayRef[ServerConfiguration] :$server_configs)
    {
        foreach my $config (@$server_configs)
        {
            $config->{return_session} ||= $self->poe->sender->ID;

            $self->yield
            (
                'connect'
                remote_address  => $config->{remote_address},
                remote_port     => $config->{remote_port},
                return_event    => 'publish_self',
                tag             => $config
            );
        }
    }

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        my $tag = $self->delete_connection_tag($id);
        $tag->{connection_id} = $self->last_wheel;
        $tag->{resolved_address} = inet_ntoa($address);
        $self->set_connection($tag->{server_alias}, $tag);
    }

    method publish_self(WheelID :$connection_id, Str :$remote_address, Int :$remote_port) is Event
    {
        $self->yield
        (
            'publish',
            connection_id   => $connection_id,
            session         => $self,
            session_alias   => $self->application_name,
            return_event    => 'check_publish_self',
        );
    }

    method check_publish_self
    (
        WheelID :$connection_id, 
        Bool :$success, 
        SessionAlias :$session_alias, 
        Ref :$payload?, 
        Ref :$tag?
    ) is Event
    {
        if($success)
        {
            my $connection = $self->get_connection($connection_id);
            $self->post
            (
                $connection->{return_session},
                $connection->{return_event},
                success             => $success,
                server_connection   => $connection,
            );
        }
    }

    method send_register_application(ServerConnectionInfo $info) is Event
    {
        
        state $msg = 
        {
            application_name        => $self->application_name,
            version                 => $self->version,
            min_participant_version => $self->min_participant_version,
            session_name            => $self->application_name,
            provides                => $self->provides,
            requires                => $self->requires,
        };

        $self->yield
        (
            'return_to_sender',
            connection_id   => $info->{connection_id},
        );
    }
}

1;
__END__
