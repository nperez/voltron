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
    use Socket;

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

    method build_register_message()
    {
        state $msg =
        {
            application_name        => $self->name,
            min_participant_version => $self->min_participant_version,
            version                 => $self->version,
            provides                => $self->provides,
            requires                => $self->requires,
        };

        return $msg;
    }

    around handle_inbound_data(VoltronMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when('participant_add')
            {
                $self->yield('handle_add_participant', $data, $id);
            }
            when('participant_remove')
            {
                $self->yield('handle_remote_participant', $data, $id);
            }
            default
            {
                $orig->($self, $data, $id);
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
            payload => nfreeze({ application_name => $self->application_name })
        };

        $self->yield
        (
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
            my $participants = $self->all_participants;
            foreach my $participant (@$participants)
            {
                if($participant->{connection_id} == $id)
                {
                    $self->post($participant->{participant_name}, 'shutdown');
                    $self->delete_participant($participant->{name});
                }
            }
            
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
        $self->yield
        (
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
            $self->add_participant($participant);
            $self->yield('participant_added', participant => $participant);
        }
        
        $self->yield
        (
            'send_result',
            success     => $success,
            wheel_id    => $connection_id,
            original    => $tag->{original},
            payload     => nfreeze($payload),
        );
    }

    method handle_remove_participant(VoltronMessage $data, WheelID $id) is Event
    {
        my $participant = thaw($data->{payload});
        $self->yield
        (
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
        SessionAlias :$session_name, 
        HashRef :$tag
    ) is Event
    {
        if($success)
        {
            my $participant = $tag->{participant};
            $self->delete_participant($participant->{name});
            $self->yield('participant_removed', participant => $participant);
        }
        
        $self->yield
        (
            'send_result',
            success     => $success,
            wheel_id    => $tag->{connection_id},
            original    => $tag->{original},
        );
    }
}

1;
__END__
