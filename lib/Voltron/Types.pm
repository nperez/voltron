package Voltron::Types;
use 5.010;

#ABSTRACT: Types for use within the Voltron environment

use Moose::Util::TypeConstraints;
use MooseX::Types -declare => 
[ 
    qw/ 
        Application
        Participant
        VoltronMessage 
        ServerConfiguration
        ServerConnectionInfo
        UnRegisterApplicationPayload
        UnRegisterParticipantPayload
    / 
];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');
use POEx::ProxySession::Types(':all');
use POEx::Types(':all');

subtype Application,
    as Dict
    [
        application_name        => SessionAlias,
        version                 => Num,
        min_participant_version => Num,
        requires                => Optional[HashRef],
        provides                => HashRef,
        participants            => Optional[HashRef],
        connection_id           => Optional[WheelID],
    ];

subtype Participant,
    as Dict
    [
        application_name    => SessionAlias,
        version             => Num,
        participant_name    => SessionAlias,
        provides            => HashRef,
        requires            => Optional[HashRef],
        connection_id       => Optional[WheelID],
    ];

subtype UnRegisterApplicationPayload,
    as Dict[ application_name => Str ];
subtype UnRegisterParticipantPayload,
    as Dict[ participant_name => Str ];


subtype ServerConfiguration,
    as Dict
    [
        remote_address      => Str,
        remote_port         => Int,
        return_session      => Optional[SessionAlias|SessionID],
        return_event        => Str,
        server_alias        => Str,
        tag                 => Optional[Ref],
    ];

subtype ServerConnectionInfo,
    as Dict
    [
        connection_id       => WheelID,
        resolved_address    => Str,
        remote_address      => Str,
        remote_port         => Int,
        return_session      => Optional[SessionAlias|SessionID],
        return_event        => Str,
        server_alias        => Str,
        tag                 => Optional[Ref],
    ];

subtype VoltronMessage,
    as ProxyMessage,
    where
    {
        my $hash = $_;
        given($hash->{type})
        {
            when('register_application')
            {
                return defined($hash->{payload});
            }
            when('register_participant')
            {
                return defined($hash->{payload});
            }
            when('unregister_application')
            {
                return defined($hash->{payload});
            }
            when('unregister_participant')
            {
                return defined($hash->{payload});
            }
            default
            {
                # passthrough
                return 1;
            }
        }
    };
    

