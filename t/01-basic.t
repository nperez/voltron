use 5.010;
use Test::More('tests', 10);

use MooseX::Declare;

BEGIN { sub POE::Kernel::CATCH_EXCEPTIONS () { 0 } }

class Tester with POEx::Role::SessionInstantiation
{
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use POE::Wheel::Run;
    use Voltron::Server;

    use aliased 'POEx::Role::Event';

    has app_wheel => (is => 'rw', isa => Object, clearer => 'clear_app_wheel');
    has par_wheel => (is => 'rw', isa => Object, clearer => 'clear_par_wheel');

    after _start is Event
    {
        Voltron::Server->new
        (
            listen_ip   => 127.0.0.1,
            listen_port => 12345,
            alias       => 'master',
            options     => { trace => 0, debug => 1 },
        );
        
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

                    has parent_wheel => (is => 'rw', isa => Object, clearer => 'clear_parent');

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
                            $self->parent_wheel->put("application_check");
                        }
                        else
                        {
                            die "Application failed to register: $$payload";
                        }
                    }

                    method participant_added(Participant :$participant) is Event
                    {
                        $self->parent_wheel->put("participant_added");
                    }

                    method participant_removed(Participant :$participant) is Event
                    {
                        $self->parent_wheel->put("participant_removed");
                        $self->terminate_application(info => $_, return_event => 'check_terminate')
                            for $self->all_serverinfos;
                    }

                    method check_terminate(Bool :$success, Ref :$payload?) is Event
                    {
                        if($success)
                        {
                            $self->parent_wheel->put("check_terminate");
                            $self->parent_wheel->flush();
                            $self->clear_parent;
                        }
                        else
                        {
                            die "Somehow failed to terminate: $$payload";
                        }
                    }

                    method flarg(Int $arg1, Str $arg2) is VoltronEvent
                    {
                        $self->parent_wheel->put("flarg");
                        
                        $self->post
                        (
                            'MyParticipant',
                            'blat',
                            1000,
                            'str_arg',
                        );
                    }
                }

                my $app = MyApplication->new
                (
                    alias                   => 'MyApplication',
                    name                    => 'MyApplication',
                    version                 => 1.00,
                    min_participant_version => 1.00,
                    requires                => { blat => '(Int $arg1, Str $arg2)' },
                    options                 => { trace => 0, debug => 1 },
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
                
                POE::Kernel->run();
            },
            StdoutEvent => 'handle_child_output',
            StderrEvent => 'handle_child_error',
        );
        
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

                    has parent_wheel => (is => 'rw', isa => Object, clearer => 'clear_parent');

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
                            $self->parent_wheel->put("participant_check");
                            $self->post
                            (
                                'MyApplication',
                                'flarg',
                                1234567,
                                'STRINGHERE',
                            );
                        }
                        else
                        {
                            die "Participant failed to register: $$payload";
                        }
                    }

                    method application_added(Application :$application) is Event
                    {
                        $self->parent_wheel->put("application_added");
                    }

                    method application_removed(Application :$application) is Event
                    {
                        $self->parent_wheel->put("application_removed");
                    }

                    method blat(Int $arg1, Str $arg2) is VoltronEvent
                    {
                        $self->parent_wheel->put("blat");
                        $self->yield('unregister_from', application => $_, return_event => 'check_unregister')
                            for $self->all_applications;
                    }

                    method check_unregister(Bool :$success, Ref :$payload?) is Event
                    {
                        if($success)
                        {
                            $self->parent_wheel->put("check_unregister");
                            $self->parent_wheel->flush();
                            $self->clear_parent;
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
                    requires                => { flarg => '(Int $arg1, Str $arg2)' },
                    options                 => { debug => 1, trace => 0 },
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
            StdoutEvent => 'handle_child_output',
            StderrEvent => 'handle_child_error',
        );

        $self->poe->kernel->sig_child($app_wheel->ID, 'handle_child_signal');
        $self->poe->kernel->sig_child($par_wheel->ID, 'handle_child_signal');
        $self->app_wheel($app_wheel);
        $self->par_wheel($par_wheel);
    }

    method handle_child_output(Str $data, WheelID $id) is Event
    {
        state $count = 0;
        Test::More::pass( "WE GOT DATA: $data" );
        $count++;
        if($count == 9)
        {
            $self->post('master', 'shutdown');
            $self->clear_app_wheel;
            $self->clear_par_wheel;
        }
    }

    method handle_child_error(Str $data, WheelID $id) is Event
    {
        warn "CHILD($id):$data";
    }

    method handle_child_signal(Str $chld, WheelID $id, Any $exit_val) is Event
    {
        warn "WE GOT $exit_val from $id";
    }
}

Tester->new(alias => 'tester', options => { trace => 0, debug => 1 });
POE::Kernel->run();
