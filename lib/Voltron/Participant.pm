package Voltron::Participant;
use 5.010;

#ABSTRACT: A role that turns objects into Voltron participants

use MooseX::Declare;

role Voltron::Participant with Voltron::Guts
{
    use Voltron::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Storable('nfreeze', 'thaw');

    use aliased 'POEx::Role::Event';
    use aliased 'Voltron::Role::VoltronEvent';

    has application_name => 
    (
        is      => 'ro',
        isa     => Str,
    );
    
    has applications =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[Application],
        default     => sub { {} },
        lazy        => 1,
        provides    => 
        {
            exists      => 'has_application',
            set         => 'set_application',
            get         => 'get_application',
            delete      => 'delete_application',
            count       => 'count_applications',
            values      => 'all_applications',
        }
    );

    requires('application_added', 'application_removed');
    
    method _build_register_message
    {
        return
        {
            type    => 'register_participant',
            id      => -1,
            payload => nfreeze
            (
                {
                    application_name        => $self->application_name,
                    participant_name        => $self->name,
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
    }

    method handle_voltron_data(VoltronMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when('application_termination')
            {
                $self->yield('handle_application_termination', $data, $id);
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

    around handle_on_register(VoltronMessage $data, WheelID $id, ServerConnectionInfo $info) is Event
    {
        if($data->{success})
        {
            my $app = thaw($data->{payload})->{application};
            $app->{connection_id} = $id;
            $self->set_application($id, $app);

            $self->yield('application_added', application => $app);

            $self->post
            (
                'PXPSClient',
                'subscribe',
                connection_id   => $id,
                to_session      => $self->application_name,
                return_event    => 'handle_application_subscription',
                tag             => $info,
            );
        }
        else
        {
            $orig->($self, $data, $id, $info);
        }
    }

    method handle_application_subscription
    (
        WheelID :$connection_id,
        Bool :$success,
        SessionAlias :$session_name,
        Ref :$payload,
        ServerConnectionInfo :$tag
    ) is Event
    {
        if($success)
        {
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                success     => $success,
                serverinfo  => $tag,
            );
        }
        else
        {
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                success     => $success,
                serverinfo  => $tag,
                payload     => $$payload,
            );
        }
    }

    method handle_application_termination(VoltronMessage $data, WheelID $id) is Event
    {
        return if not $self->has_application($id);

        my $app = $self->delete_application($id);
        $self->post
        (
            'PXPSClient',
            'unsubscribe',
            session_name    => $app->{application_name},
            return_event    => 'handle_application_unsubscription',
            tag             =>
            {
                connection_id   => $id,
                application     => $app,
            }
        );
    }

    method handle_application_unsubscription(Bool :$success, SessionAlias :$session_alias, HashRef :$tag) is Event
    {
        if($success)
        {
            $self->delete_application($tag->{application}->{connection_id});
            $self->yield('application_removed', application => $tag->{application});

            if(exists($tag->{return_session}))
            {
                $self->post
                (
                    $tag->{return_session},
                    $tag->{return_event},
                    success     => $success,
                );
            }

            $self->post('PXPSClient', 'shutdown');
            $self->clear_alias;
        }
        else
        {
            die "Something went wrong unsubscribing from the proxied application session";
        }
    }

    method unregister_from
    (
        Application :$application, 
        SessionID|SessionAlias|Session|DoesSessionInstantiation :$return_session?,
        Str :$return_event
    ) is Event
    {
        state $msg = 
        {
            type    => 'unregister_participant',
            id      => -1, 
            payload => nfreeze({ participant_name => $self->name })
        };

        $self->post
        (
            'PXPSClient',
            'return_to_sender',
            message         => $msg,
            wheel_id        => $application->{connection_id},
            return_session  => $self->ID,
            return_event    => 'handle_unregister_from',
            tag             =>
            {
                application     => $application,
                return_session  => $return_session // $self->poe->sender->ID,
                return_event    => $return_event,
            }
        );
    }

    method handle_unregister_from(VoltronMessage $data, WheelID $id, HashRef $tag) is Event
    {
        if($data->{success})
        {
            $self->post
            (
                'PXPSClient',
                'unsubscribe',
                session_name    => $tag->{application}->{application_name},
                return_event    => 'handle_application_unsubscription',
                tag             =>
                {
                    connection_id   => $id,
                    application     => $tag->{application},
                    return_session  => $tag->{return_session},
                    return_event    => $tag->{return_event},
                }
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
}
1;
__END__
