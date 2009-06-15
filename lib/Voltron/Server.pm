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
    use aliased 'POEx::Role::ProxyEvent';

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

    around handle_inbound_data(VoltronMessage $data, WheelID $id) is Event
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

    method register_application(VoltronMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => RegisterApplicationPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Payload is invalid: $msg"
            );
            return;
        }

        my $application_name = $payload->{application_name};

        if($self->has_application($application_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Application '$application_name' already exists"
            );
        }
        elsif(!$self->has_session($application_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Associated session '$application_name' does not exist"
            );
        }
        elsif(!$self->check_provides($application_name, $payload->{provides}))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \'Provides does not exactly match published session events'
            );
        }
        else
        {
            $self->set_application
            (
                $application_name,
                {
                    application_name        => $application_name,
                    version                 => $payload->{version},
                    min_participant_version => $payload->{min_participant_version},
                    requires                => $payload->{requires},
                    provides                => $payload->{provides},
                    participants            => []
                }
            );

            $self->yield
            (
                'send_result', 
                success     => 1,
                original    => $data, 
                wheel_id    => $id
            );
        }
    }

    method register_participant(VoltronMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => RegisterParticipantPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Payload is invalid: $msg"
            );
            return;
        }
        
        my $participant_name = $payload->{participant_name};
        my $application_name = $payload->{application_name};

        if(!$self->has_application($application_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Application '$application_name' doesn't exist"
            );
        }
        elsif($self->has_participant($participant_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Participant '$participant_name' already exists"
            );
        }
        elsif(!$self->has_session($participant_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Participant has not published a session named '$participant_name'"
            );
        }
        else
        {
            my $app = $self->get_application($application_name);
            my $appver = $app->{min_participant_version};
            my $parver = $payload->{version};
            
            if(!$appver <= $parver)
            {
                $self->yield
                (
                    'send_result', 
                    success     => 0,
                    original    => $data, 
                    wheel_id    => $id, 
                    payload     => \"Participant version '$parver' is too low for application min '$appver'"
                );
            }
            if(!$self->check_provides($participant_name, $app->{requires}))
            {
                $self->yield
                (
                    'send_result', 
                    success     => 0,
                    original    => $data, 
                    wheel_id    => $id, 
                    payload     => \"Participant provides do not matach what the application requires"
                );
            }
            elsif(!$self->check_provides($application_name, $payload->{requires}))
            {
                $self->yield
                (
                    'send_result', 
                    success     => 0,
                    original    => $data, 
                    wheel_id    => $id, 
                    payload     => \"Application provides do not match what the participant requires"
                );
            }
            else
            {
                my $participant = 
                {
                    participant_name    => $participant_name,
                    application_name    => $application_name,
                    version             => $parver,
                    provides            => $payload->{provides},
                    requires            => $payload->{requires},
                };

                $self->yield
                (
                    'send_app_participant_add', 
                    application     => $app, 
                    participant     => $participant,
                    tag         =>
                    {
                        application     => $application,
                        participant     => $participant,
                        connection_id   => $id,
                        original        => $data,
                    }
                );
            }
        }
    }

    method unregister_application(VoltronMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => UnRegisterApplicationPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Payload is invalid: $msg"
            );
            return;
        }
        
        my $application_name = $payload->{application_name};

        if(!$self->has_application($application_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Application '$application_name' doesn't exist"
            );
            return;
        }
        
        foreach my $participant ( values %{ $self->get_application($application_name)->{participants} } )
        {
            $self->yield('send_participant_termination', $participant);
        }

        $self->delete_application($application_name);

        $self->yield
        (
            'send_result', 
            success     => 1,
            original    => $data, 
            wheel_id    => $id
        );
    }

    method unregister_participant(VoltronMessage $data, WheelID $id) is Event
    {
        state $validator = MooseX::Meta::TypeConstraint::ForceCoercion->new(type_constraint => UnRegisterParticipantPayload);

        my $payload = thaw($data->{payload});
        
        if( defined ( my $msg = $validator->validate( $payload ) ) )
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Payload is invalid: $msg"
            );
            
            return;
        }
        
        my $part_name = $payload->{participant_name};
        if(!$self->has_participant($part_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Participant '$part_name' doesn't exist"
            );
            return;
        }

        my $part = $self->get_participant($part_name);
        my $app = $self->get_application($part->{application});

        $self->yield
        (
            'send_app_participant_remove', 
            application     => $app, 
            participant     => $part,
            tag         =>
            {
                participant     => $part,
                connection_id   => $id,
                original        => $data,
            }
        );
    }

    method check_provides(SessionAlias $session_name, MethodHash $requires) is Event
    {
        my $meta = $self->get_session($session_name)->{meta};
        
        while(my ($name, $obj) = each %{ $meta->{methods} })
        {
            if($obj->isa('Class::MOP::Method::Wrapped'))
            {
                my $orig = $obj->get_original_method;
                if(!$orig->meta->isa('Moose::Meta::Class') || !$orig->meta->does_role(ProxyEvent))
                {
                    next;
                }
                
                $obj = $orig;
            }
            elsif(!$obj->meta->isa('Moose::Meta::Class') || !$obj->meta->does_role(ProxyEvent))
            {
                next;
            }

            return 0 if not exists($requires->{$name});
            return 0 if $obj->signature ne delete($requires->{$name});
        }

        return 0 if keys %$requires;
        return 1;
    }

    method send_app_participant_add
    (
        Application :$application,
        Participant :$participant,
        HashRef :$tag
    ) is Event
    {
        my $message =
        {
            type    => 'participant_add',
            id      => -1,
            payload => nfreeze($participant),
        };

        $self->yield
        (
            'return_to_sender',
            message         => $message,
            wheel_id        => $self->get_session($application->{application_name})->{wheel},
            return_session  => $self->ID,
            return_event    => 'handle_participant_add',
            tag             => $tag
        );
    }

    method handle_participant_add(VoltronMessage $data, WheelID $id, HashRef $tag) is Event
    {
        my $payload;

        if($data->{success})
        {
            my $participant = $tag->{participant};
            my $application = $tag->{application};

            $application->{participants}->{$participant->{name}} = $participant;
            $self->add_participant($participant->{name}, $participant);
            $payload = { application => $application };
        }

        my %args =
        (
            success     => $data->{success},
            wheel_id    => $tag->{connection_id},
            original    => $tag->{original},
        );
        
        $args{'payload'} = $payload // (thaw($data->{payload}) if defined($data->{payload}));

        $self->yield
        (
            'send_result',
            %args,
        );
    }

    method send_app_participant_remove
    (
        Application :$application,
        Participant :$participant,
        HashRef :$tag
    ) is Event
    {
        my $message =
        {
            type    => 'participant_remove',
            id      => -1,
            payload => nfreeze($participant),
        };

        $self->yield
        (
            'return_to_sender',
            message         => $message,
            wheel_id        => $self->get_session($application->{application_name})->{wheel},
            return_session  => $self->ID,
            return_event    => 'handle_participant_remove',
            tag             => $tag
        );
    }

    method handle_participant_remove(VoltronMessage $data, WheelID $id, HashRef $tag) is Event
    {
        if($data->{success})
        {
            my $participant = $tag->{participant};
            my $application = $self->get_application($participant->{application_name});

            delete($application->{participants}->{$participant->{name}});
            $self->delete_participant($participant->{name});
        }

        my %args =
        (
            success     => $data->{success},
            wheel_id    => $tag->{connection_id},
            original    => $tag->{original},
        );

        $args{'payload'} = thaw($data->{payload}) if defined($data->{payload});

        $self->yield
        (
            'send_result',
            %args,
        );
    }

    method send_participant_termination(Participant $part) is Event
    {
        $self->yield
        (
            'send_mesage',
            type        => 'application_termination',
            wheel_id    => $self->get_session($part->{participant_name})->{wheel},
            payload     => $part,
        );
    }
}
1;
__END__
