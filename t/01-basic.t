use 5.010;
use Test::More('tests', 10);

use MooseX::Declare;

class Tester with POEx::Role::SessionInstantiation
{
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use POE::Wheel::Run;
    use Voltron::Server;

    use aliased 'POEx::Role::Event';

    has app_wheel => (is => 'rw', isa => Object);

    after _start is Event
    {
        Voltron::Server->new
        (
            listen_ip   => 127.0.0.1,
            listen_port => 12345,
            alias       => 'master',
            options     => { trace => 1, debug => 1 },
        );
        
        warn "app wheel";
        my $app_wheel = POE::Wheel::Run->new
        (
            Program => sub
            {
                POE::Kernel->stop();

                class MyApplication with Voltron::Application
                {
                    use POEx::Types(':all');
                    use Voltron::Types(':all');
                    use MooseX::Types::Moose(':all');

                    use aliased 'POEx::Role::Event';
                    use aliased 'Voltron::Role::VoltronEvent';

                    has parent_wheel => (is => 'rw', isa => Object);

                    after _start is Event
                    {
                        my $parent_wheel = POE::Wheel::ReadWrite->new
                        (
                            InputHandle     => \*STDIN,
                            OutputHandle    => \*STDOUT,
                            InputEvent      => 'parent_input',
                        );

                        $self->parent_wheel($parent_wheel);
                    }

                    method application_check(Bool :$success, ServerConnectionInfo :$serverinfo, Ref :$payload?) is Event
                    {
                        if($success)
                        {
                            $self->parent_wheel->put("application_check\n");
                        }
                        else
                        {
                            die "Application failed to register: $$payload";
                        }
                    }

                    method participant_added(Participant :$participant)
                    {
                        $self->post
                        (
                            $participant->{participant_name},
                            'blat',
                            'str_arg',
                            1000,
                        );
                        $self->parent_wheel->put("participant_added\n");
                    }

                    method participant_removed(Participant :$participant)
                    {
                        $self->parent_Wheel->put("participant_removed\n");
                        $self->terminate_application(info => $_, return_event => 'terminate')
                            for @{ $self->all_serverinfos };
                    }

                    method flarg(Int $arg1, Str $arg2) is VoltronEvent
                    {
                        $self->parent_wheel->put("flarg\n");
                    }
                }

                my $app = MyApplication->new
                (
                    alias                   => 'MyApplication',
                    name                    => 'MyApplication',
                    version                 => 1.00,
                    min_participant_version => 1.00,
                    requires                => { blat => '(Str $arg1, Int $arg2)' },
                    options                 => { trace => 1, debug => 1 },
                    server_configs =>
                    [
                        {
                            remote_address  => '127.0.0.1',
                            remote_port     => 12345,
                            return_session  => 'MyApplication',
                            return_event    => 'application_check',
                            server_alias    => 'test_server',
                        }
                    ]

                );
                warn $app->provides;
                
                POE::Kernel->run();
            },
            StdoutEvent => 'handle_child_ouput',
            StderrEvent => 'handle_child_error',
        );
        
        warn "par wheel";
        my $par_wheel = POE::Wheel::Run->new
        (
            Program => sub
            {
                POE::Kernel->stop();

                class MyParticipant with Voltron::Participant
                {
                    use POEx::Types(':all');
                    use Voltron::Types(':all');
                    use MooseX::Types::Moose(':all');

                    use aliased 'POEx::Role::Event';
                    use aliased 'Voltron::Role::VoltronEvent';

                    has parent_wheel => (is => 'rw', isa => Object);

                    after _start is Event
                    {
                        my $parent_wheel = POE::Wheel::ReadWrite->new
                        (
                            InputHandle     => \*STDIN,
                            OutputHandle    => \*STDOUT,
                            InputEvent      => 'parent_input',
                        );

                        $self->parent_wheel($parent_wheel);
                    }

                    method participant_check(Bool :$success, ServerConnectionInfo :$serverinfo, Ref :$payload?) is Event
                    {
                        if($success)
                        {
                            $self->parent_wheel->put("participant_check\n");
                            $self->post
                            (
                                'MyApplication',
                                'flarg',
                                'STRINGHERE',
                                1234567,
                            );
                        }
                        else
                        {
                            die "Participant failed to register: $$payload";
                        }
                    }

                    method application_added(Application :$participant)
                    {
                        $self->parent_wheel->put("application_added\n");
                    }

                    method application_removed(Application :$participant)
                    {
                        $self->parent_wheel->put("application_removed\n");
                    }

                    method blat(Int $arg1, Str $arg2) is VoltronEvent
                    {
                        $self->parent_wheel->put("blat\n");
                        $self->yield('unregister_from', application => $_, return_event => 'check_unregister')
                            for @{ $self->all_applications };
                    }

                    method check_unregister(Bool :$success, Ref :$payload?)
                    {
                        if($success)
                        {
                            $self->parent_wheel->put("check_unregister");
                        }
                        else
                        {
                            die "Failed to unregister somehow: $$payload";
                        }
                    }
                }

                my $par = MyParticipant->new
                (
                    alias                   => 'MyParticipant',
                    name                    => 'MyParticipant',
                    application_name        => 'MyApplication',
                    version                 => 1.00,
                    requires                => { flarg => '(Str $arg1, Int $arg2)' },
                    options                 => { debug => 1, trace => 1 },
                    server_configs =>
                    [
                        {
                            remote_address  => '127.0.0.1',
                            remote_port     => 12345,
                            return_session  => 'MyParticipant',
                            return_event    => 'participant_check',
                            server_alias    => 'test_server',
                        }
                    ]
                );

                POE::Kernel->run();
            },
            StdoutEvent => 'handle_child_ouput',
            StderrEvent => 'handle_child_error',
        );

        $self->poe->kernel->sig_child($app_wheel->ID, 'handle_child_signal');
        $self->poe->kernel->sig_child($par_wheel->ID, 'handle_child_signal');
        $self->app_wheel($app_wheel);
        $self->par_wheel($par_wheel);
    }

    method handle_child_output(Str $data, WheelID $id) is Event
    {
        warn "WE GOT DATA: $data";
    }

    method handle_child_error(Str $data, WheelID $id) is Event
    {
        warn "$data";
    }

    method handle_child_signal(Str $chld, WheelID $id, Any $exit_val) is Event
    {
        warn "WE GOT $exit_val from $id";
    }
}

Tester->new(alias => 'tester', options => { trace => 1, debug => 1 });
POE::Kernel->run();
