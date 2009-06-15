package Voltron::Role::VoltronEvent;

#ABSTRACT: Provide a decorator to label events that participate in Voltron

use MooseX::Declare;

role Voltron::Role::VoltronEvent with POEx::Role::ProxyEvent
{
}
1;
__END__
=head1 DESCRIPTION

This role is merely a decorator for methods to indicate that the method should
be available for Voltron participants and applications.

