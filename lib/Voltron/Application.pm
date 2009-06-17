package Voltron::Application;
use 5.010;

#ABSTRACT: A role that turns objects into Voltron applications

use MooseX::Declare;

role Voltron::Application with Voltron::Guts
{
    use Voltron::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Storable('nfreeze', 'thaw');

    use aliased 'POEx::Role::Event';
    use aliased 'Voltron::Role::VoltronEvent';

    has min_participant_version =>
    (
        is      => 'ro',
        isa     => Num,
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

    requires('participant_added', 'participant_removed');

    method _build_register_message
    {
        return
        {
            type    => 'register_application',
            id      => -1,
            payload => nfreeze
            (
                {
                    application_name        => $self->name,
                    min_participant_version => $self->min_participant_version,
                    version                 => $self->version,
                    provides                => $self->provides,
                    requires                => $self->requires,
                }
            ),
        };
    }
    
    after _start is Event
    {
        $self->proxyclient->unknown_message_event([$self->ID, 'handle_voltron_data']);
        $self->provides;
    }

    method handle_voltron_data(VoltronMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when('participant_add')
            {
                $self->yield('handle_add_participant', $data, $id);
            }
            when('participant_remove')
            {
                $self->yield('handle_remove_participant', $data, $id);
            }
            default
            {
                warn qq|Received unknown message type from the server ${\$data->{type}}|;
                $self->post
                (
                    'PXPSClient',
                    'send_result',
                    success         => 0,
                    wheel_id        => $id,
                    original        => $data,
                    payload         => \'Unknown message type'
                );
            }
        }
    }
    
    method terminate_application
    (
        ServerConnectionInfo :$info,
        SessionID|SessionAlias|Session|DoesSessionInstantiation :$return_session?,
        Str :$return_event
    ) is Event
    {
        state $message =
        {
            type    => 'unregister_application',
            id      => -1,
            payload => nfreeze({ application_name => $self->name })
        };

        $self->post
        (
            'PXPSClient',
            'return_to_sender',
            message         => $message,
            wheel_id        => $info->{connection_id},
            return_session  => $self->ID,
            return_event    => 'handle_termination',
            tag             => 
            { 
                return_session => $return_session // $self->ID, 
                return_event => $return_event 
            }
        );
    }

    method handle_termination(VoltronMessage $data, WheelID $id, Ref $tag) is Event
    {
        if($data->{success})
        {
            foreach my $participant ($self->all_participants)
            {
                if($participant->{connection_id} == $id)
                {
                    $self->post($participant->{participant_name}, 'shutdown');
                    $self->delete_participant($participant->{participant_name});
                }
            }

            $self->post('PXPSClient', 'shutdown');
            $self->clear_alias;
            
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                success     => $data->{success}
            );
        }
        else
        {
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                success     => $data->{success},
                payload     => thaw($data->{payload}),
            );
        }
    }

    method handle_add_participant(VoltronMessage $data, WheelID $id) is Event
    {
        my $participant = thaw($data->{payload});
        $self->post
        (
            'PXPSClient',
            'subscribe',
            connection_id   => $id,
            to_session      => $participant->{participant_name},
            return_event    => 'handle_participant_subscription',
            tag             => 
            {
                original        => $data,
                participant     => $participant,
            }

        );
    }

    method handle_participant_subscription
    (
        WheelID :$connection_id,
        Bool :$success, 
        SessionAlias :$session_name, 
        Ref :$payload, 
        HashRef :$tag
    ) is Event
    {
        if($success)
        {
            my $participant = $tag->{participant};
            $participant->{connection_id} = $connection_id;
            $self->set_participant($participant->{participant_name}, $participant);
            $self->yield('participant_added', participant => $participant);
        }
        
        $self->post
        (
            'PXPSClient',
            'send_result',
            success     => $success,
            wheel_id    => $connection_id,
            original    => $tag->{original},
            payload     => $payload,
        );
    }

    method handle_remove_participant(VoltronMessage $data, WheelID $id) is Event
    {
        my $participant = thaw($data->{payload});
        $self->post
        (
            'PXPSClient',
            'unsubscribe',
            session_name    => $participant->{participant_name},
            return_event    => 'handle_participant_unsubscription',
            tag             => 
            {
                original        => $data,
                participant     => $participant,
                connection_id   => $id,
            }

        );
    }

    method handle_participant_unsubscription
    (
        Bool :$success, 
        SessionAlias :$session_alias, 
        HashRef :$tag
    ) is Event
    {
        if($success)
        {
            my $participant = $tag->{participant};
            $self->delete_participant($participant->{participant_name});
            $self->yield('participant_removed', participant => $participant);
        }
        
        $self->post
        (
            'PXPSClient',
            'send_result',
            success     => $success,
            wheel_id    => $tag->{connection_id},
            original    => $tag->{original},
        );
    }
}

1;
__END__
