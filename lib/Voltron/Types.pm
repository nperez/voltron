package Voltron::Types;
use 5.010;

#ABSTRACT: Types for use within the Voltron environment

use Moose::Util::TypeConstraints;
use MooseX::Types -declare => 
[ 
    qw/ 
        MethodHash
        Application
        Participant
        VoltronMessage 
        ServerConfiguration
        RegisterApplicationPayload
        RegisterParticipantPayload
        UnRegisterApplicationPayload
        UnRegisterParticipantPayload
    / 
];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');
use POEx::ProxySession::Types(':all');
use POEx::Types(':all');

use aliased 'MooseX::Method::Signatures::Meta::Method';

class_type Method;

subtype MethodHash,
    as HashRef[Method];

subtype Application,
    as Dict
    [
        session_name            => SessionAlias,
        version                 => Num,
        min_participant_version => Num,
        requires                => Optional[MethodHash],
        provides                => MethodHash,
        participants            => ArrayRef,
    ];

subtype Participant,
    as Dict
    [
        application     => Str,
        version         => Num,
        session_name    => SessionAlias,
        provides        => MethodHash,
        requires        => Optional[MethodHash],
    ];

subtype RegisterApplicationPayload,
    as Dict
    [
        application_name        => Str,
        version                 => Num,
        min_participant_version => Num,
        session_name            => SessionAlias,
        provides                => MethodHash,
        requires                => Optional[MethodHash],
    ];

subtype RegisterParticipantPayload,
    as Dict
    [
        participant_name        => Str,
        application_name        => Str,
        version                 => Num,
        session_name            => SessionAlias,
        provides                => MethodHash,
        requires                => Optional[MethodHash],
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
    as ServerConfiguration
    [
        connection_id       => WheelID,
        resolved_address    => Str,
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
    

