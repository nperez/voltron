package Voltron::Guts;
use 5.010;

#ABSTRACT: A role that provides Voltron core behavior

use MooseX::Declare;

role Voltron::Guts with POEx::Role::SessionInstantiation
{
    use Voltron::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use POEx::ProxySession::Client;
    use YAML('Load', 'Dump');
    use Socket;

    use aliased 'POEx::Role::Event';
    use aliased 'Voltron::Role::VoltronEvent';

    has name => 
    (
        is      => 'ro',
        isa     => Str,
    );
    
    has version =>
    (
        is      => 'ro',
        isa     => Num,
    );

    has requires =>
    (
        is      => 'ro',
        isa     => HashRef,
    );
    
    has provides =>
    (
        is              => 'ro',
        isa             => HashRef,
        lazy            => 1,
        builder         => '_build_provides',
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

    has proxyclient =>
    (
        is          => 'ro',
        isa         => 'POEx::ProxySession::Client',
        default     => method
        {
            POEx::ProxySession::Client->new(alias => 'PXPSClient', options => { trace => 1, debug => 1 }); 
        }
    );

    has register_message =>
    (
        is          => 'ro',
        isa         => VoltronMessage,
        lazy_build  => 1,
    );

    has server_configs => ( is => 'rw', isa => ArrayRef[ServerConfiguration] );

    requires('_build_register_message');

    after _start is Event
    {
        foreach my $config (@{ $self->server_configs })
        {
            $config->{return_session} ||= $self->poe->sender->ID;

            $self->post
            (
                'PXPSClient',
                'connect',
                remote_address  => $config->{remote_address},
                remote_port     => $config->{remote_port},
                return_event    => 'publish_self',
                tag             => $config
            );
        }
    }

    method _build_provides
    {
        my $hash = {};
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
            
            $hash->{$method->name} = $method->signature;
        }
        
        return $hash;
    }

    method publish_self(WheelID :$connection_id, Str :$remote_address, Int :$remote_port, ServerConfiguration :$tag) is Event
    {
        $tag->{resolved_address} = $remote_address;
        $tag->{connection_id} = $connection_id;

        $self->set_serverinfo($connection_id, $tag);

        $self->post
        (
            'PXPSClient',
            'publish',
            connection_id   => $connection_id,
            session         => $self,
            session_alias   => $self->name,
            return_event    => 'check_publish_self',
            tag             => $tag,
        );
    }

    method check_publish_self
    (
        WheelID :$connection_id, 
        Bool :$success, 
        SessionAlias :$session_alias, 
        Ref :$payload?, 
        ServerConnectionInfo :$tag
    ) is Event
    {
        if($success)
        {
            $self->yield('send_register', $tag);
        }
        else
        {
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                success     => 0,
                serverinfo  => $tag,
                payload     => $payload
            );
        }
    }

    method send_register(ServerConnectionInfo $info) is Event
    {
        $self->post
        (
            'PXPSClient',
            'return_to_sender',
            message         => $self->register_message,
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
                success     => $data->{success},
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
                payload     => Load($data->{payload}),
            );
        }
    }
}
1;
__END__
