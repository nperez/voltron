package Voltron::Types;
use 5.010;

#ABSTRACT: Types for use within the Voltron environment

use Moose::Util::TypeConstraints;
use MooseX::Types -declare => [ qw/ VoltronMessage / ];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');
use POEx::ProxySession::Types(':all');
use POEx::Types(':all');

class_type 'MooseX::Method::Signatures::Meta::Method';

subtype MethodHash,
    as HashRef[MooseX::Method::Signatures::Meta::Method];

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

subtype RegisterParticipantPayload
    as Dict
    [
        participant_name        => Str,
        application_name        => Str,
        version                 => Num,
        session_name            => SessionAlias,
        provides                => MethodHash,
        requires                => Optional[MethodHash],
    ];

subtype UnRegisterApplicationPayload
subtype UnRegisterParticipantPayload

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
    

