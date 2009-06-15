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

    has serverinfos =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[ServerConnectionInfo],
        default     => sub { {} },
        lazy        => 1,
        provides    => 
        {
            exists      => 'has_serverinfo',
            set         => 'set_serverinfo',
            get         => 'get_serverinfo',
            delete      => 'delete_serverinfo',
            count       => 'count_serverinfos',
            values      => 'all_serverinfos',
        }
    );

    has participants =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[Participant],
        default     => sub { {} },
        lazy        => 1,
        provides    => 
        {
            exists      => 'has_participant',
            set         => 'set_participant',
            get         => 'get_participant',
            delete      => 'delete_participant',
            count       => 'count_participants',
            values      => 'all_participants',
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
        given($data->{type})
        {
            when('participant_add')
            {
                $self->yield('add_participant', $data, $id);
            }
            when('participant_remove')
            {
                $self->yield('remote_participant', $data, $id);
            }
            default
            {
                $orig->($self, $data, $id);
            }
        }
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

        POE::Kernel->run();
    }

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        my $tag = $self->delete_connection_tag($id);
        $tag->{connection_id} = $self->last_wheel;
        $tag->{resolved_address} = inet_ntoa($address);
        $self->set_serverinfo($tag->{connection_id}, $tag);
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
        my $info = $self->get_serverinfo($connection_id);
        if($success)
        {
            $self->yield('send_register_application', $info);
        }
        else
        {
            $self->post
            (
                $info->{return_session},
                $info->{return_event},
                success     => 0,
                serverinfo  => $info,
                payload     => $payload
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
            wheel_id        => $info->{connection_id},
            return_session  => $self->ID,
            return_event    => 'handle_on_register',
            tag             => $info
        );
    }

    method handle_on_register(VoltronMessage $data, WheelID $id, ServerConnectionInfo $info) is Event
    {
        if($data->{success})
        {
            $self->post
            (
                $info->{return_session},
                $info->{return_event},
                success     => $success,
                serverinfo  => $info,
            );
        }
        else
        {
            $self->post
            (
                $info->{return_session},
                $info->{return_event},
                success     => $data->{success},
                serverinfo  => $info,
                payload     => thaw($data->{payload},
            );
        }
    }
}

1;
__END__
