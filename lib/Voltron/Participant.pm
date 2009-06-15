package Voltron::Participant;
use 5.010;

#ABSTRACT: A role that turns objects into Voltron participants

use MooseX::Declare;

role Voltron::Participant with POEx::ProxySession::Client
{
    use Voltron::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Socket;

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
        isa         => HashRef[Participant],
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

    around handle_inbound_data(VoltronMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when('application_termination')
            {
                $self->yield('handle_application_termination', $data, $id);
            }
            default
            {
                $orig->($self, $data, $id);
            }
        }
    }

    method build_register_message()
    {
        state $msg = 
        {
            application_name        => $self->application_name,
            participant_name        => $self->name,
            version                 => $self->version,
            provides                => $self->provides,
            requires                => $self->requires,
        };

        return $msg;
    }

    around handle_on_register(VoltronMessage $data, WheelID $id, ServerConnectionInfo $info) is Event
    {
        if($data->{success})
        {
            my $app = thaw($data->{payload})->{application};
            $app->{connection_id} = $id;
            $self->set_application($id, $app);

            $self->yield('application_added', application => $app);

            $self->yield
            (
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
        my $app = $self->delete_application($id);
        $self->yield
        (
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
            $self->delete_wheel($tag->{connection_id});
            $self->yield('application_removed', application => $tag->{application});
        }
        else
        {
            die "Something went wrong unsubscribing from the proxied application session";
        }
    }
}
1;
__END__
