use 5.010;
use MooseX::Declare;

class Voltron::Server extends POEx::ProxySession::Server
{
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use MooseX::Meta::TypeConstraint::ForceCoercion;
    use POEx::Types(':all');
    use POEx::ProxySession::Types(':all');
    use Voltron::Types(':all');
    use Storable('thaw', 'nfreeze');
    use aliased 'POEx::Role::Event';

    has applications => 
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_application',
        provides    => 
        {
            get     => 'get_application',
            set     => 'set_application',
            delete  => 'delete_application',
            count   => 'count_application',
            exists  => 'has_application',
        }
    );

    has participants => 
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_participant',
        provides    => 
        {
            get     => 'get_participant',
            set     => 'set_participant',
            delete  => 'delete_participant',
            count   => 'count_participant',
            exists  => 'has_participant',
        }
    );

    around handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when('register_application')
            {
                $self->yield('register_application', $data, $id);
            }
            when('register_participant')
            {
                $self->yield('register_participant', $data, $id);
            }
            when('unregister_application')
            {
                $self->yield('unregister_application', $data, $id);
            }
            when('unregister_participant')
            {
                $self->yield('unregister_participant', $data, $id);
            }
            default
            {
                $orig->($self, $data, $id);
            }
        }
    }

    method register_application(ProxyMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => RegisterApplicationPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield('return_error', $data, $id, "Payload is invalid: $msg");
            return;
        }

        my $application_name = $payload->{application_name};
        my $session_name = $payload->{session_name};

        if($self->has_application($application_name))
        {
            $self->yield('return_error', $data, $id, "Application '$application_name' already exists");
        }
        elsif(!$self->has_session($session_name))
        {
            $self->yield('return_error', $data, $id, "Associated session '$session_name' does not exist");
        }
        elsif(!$self->check_provides($session_name, $payload->{provides}))
        {
            $self->yield('return_error', $data, $id, 'Provides does not exactly match published session events');
        }
        else
        {
            $self->set_application
            (
                $application_name,
                {
                    session_name            => $session_name,
                    version                 => $payload->{version},
                    min_participant_version => $payload->{min_participant_version},
                    requires                => $payload->{requires},
                    provides                => $payload->{provides},
                    participants            => []
                }
            );

            $self->yield('return_success', $data, $id);
        }
    }

    method register_participant(ProxyMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => RegisterParticipantPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield('return_error', $data, $id, "Payload is invalid: $msg");
            return;
        }
        
        my $participant_name = $payload->{participant_name};
        my $application_name = $payload->{application_name};
        my $part_session_name = $payload->{session_name};

        if(!$self->has_application($application_name))
        {
            $self->yield('return_error', $data, $id, "Application '$application_name' doesn't exist");    
        }
        elsif($self->has_participant($participant_name))
        {
            $self->yield('return_error', $data, $id, "Participant '$participant_name' already exists");
        }
        elsif(!$self->has_session($part_session_name))
        {
            $self->yield('return_error', $data, $id, "Participant has not published a session named '$part_session_name");
        }
        else
        {
            my $app = $self->get_application($application_name);
            my $appver = $app->{min_participant_version};
            my $parver = $payload->{version};
            
            if(!$appver <= $parver)
            {
                $self->yield('return_error', $data, $id, "Participant version '$parver' is too low for application min '$appver");
            }
            if(!$self->check_provides($part_session_name, $app->{requires}))
            {
                $self->yield('return_error', $data, $id, 'Participant provides do not matach what the application requires');
            }
            elsif(!$self->check_provides($app->{session_name}, $payload->{requires}))
            {
                $self->yield('return_error', $data, $id, 'Application provides do not match what the participant requires');
            }
            else
            {
                my $participant = 
                {
                    application     => $application_name,
                    session_name    => $part_session_name,
                    version         => $parver,
                    provides        => $payload->{provides},
                    requires        => $payload->{requires},
                };

                $self->set_participant($participant_name, $participant);
                $app->{participants}->{$participant_name} = $participant;

                $self->yield('send_app_participant_add', $app, $participant);

                $self->yield('return_success', $data, $id, $app);
            }
        }
    }

    method unregister_application(ProxyMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => UnRegisterApplicationPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield('return_error', $data, $id, "Payload is invalid: $msg");
            return;
        }
        
        if(!$self->has_application($application_name))
        {
            $self->yield('return_error', $data, $id, "Application '$application_name' doesn't exist");
            return;
        }
        
        foreach my $participant ( values %{ $self->get_application($application_name)->{participants} } )
        {
            $self->yield('send_participant_termination', $participant);
        }

        $self->delete_application($application_name);

        $self->yield('return_success', $data, $id);
    }

    method unregister_participant(ProxyMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => UnRegisterParticipantPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield('return_error', $data, $id, "Payload is invalid: $msg");
            return;
        }
        
        my $part_name = $payload->{participant_name};
        if(!$self->has_participant($part_name))
        {
            $self->yield('return_error', $data, $id, "Participant '$part_name' doesn't exist");
            return;
        }

        my $part = $self->delete_participant($part_name);
        my $app = $self->get_application($part->{application});
        delete($app->{participants}->{$part_name});

        $self->yield('send_app_participant_remove', $app, $part);
        $self->yield('return_success', $data, $id);
    }

    method send_app_participant_add(Application $app, Participant $part) is Event
    {
        my $wheel_id = $self->get_session($app->{session_name})->{wheel};
        $self->
    }

    method send_app_participant_remove(Application $app, Participant $part) is Event
    {
    }

    method send_participant_termination(Participant $part) is Event
    {
    }
1;
