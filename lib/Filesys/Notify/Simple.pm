package Filesys::Notify::Simple;

use strict;
use 5.008_001;
our $VERSION = '0.07';

use Carp ();
use Cwd;
use constant NO_OPT => $ENV{PERL_FNS_NO_OPT};

sub new {
    my($class, $path, %opt) = @_;

    unless (ref $path eq 'ARRAY') {
        Carp::croak('Usage: Filesys::Notify::Simple->new([ $path1, $path2 ])');
    }

    my $self = bless { paths => $path }, $class;
    if (defined($opt{Detail})) {
        $self->{detail} = $opt{Detail};
    } else {
        $self->{detail} = 1;
    }
    
    if (defined($opt{Latency})) {
        $self->{latency} = $opt{Latency};
    } else {
        $self->{latency} = 2;
    }

    if (defined($opt{Method})) {
        $self->{method} = $opt{Method};
    }

    $self->init;

    $self;
}

sub wait {
    my($self, $cb) = @_;

    $self->{watcher} ||= $self->{watcher_cb}->($self, @{$self->{paths}});
    $self->{watcher}->($cb);
}

sub init {
    my $self = shift;

    local $@;
    if (!$self->{method}) {
        if ($^O eq 'linux' && !NO_OPT && eval { require Linux::Inotify2; 1 }) {
            $self->{method} = 'inotify2';
        } elsif ($^O eq 'darwin' && !NO_OPT && eval { require Mac::FSEvents; 1 }) {
            $self->{method} = 'fsevents';
        } else {
            $self->{method} = 'timer';
        }
    }

    if ($self->{method} eq 'inotify2') {
	require Linux::Inotify2;
        $self->{watcher_cb} = \&wait_inotify2;
    } elsif ($self->{method} eq 'fsevents') {
	require Mac::FSEvents;
	$self->{watcher_cb} = \&wait_fsevents;
    } elsif ($self->{method} eq 'timer') {
        $self->{watcher_cb} = \&wait_timer;
    } else {
        die "Invalid method requested\n";
    }
}

sub wait_inotify2 {
    my $obj = shift;
    my @path = @_;

    Linux::Inotify2->import;
    my $inotify = Linux::Inotify2->new;

    my $fs = _full_scan(@path);
    for my $path (keys %$fs) {
        $inotify->watch($path, &IN_MODIFY|&IN_CREATE|&IN_DELETE|&IN_DELETE_SELF|&IN_MOVE_SELF);
    }

    return sub {
        my $cb = shift;
        $inotify->blocking(1);
        my @events = $inotify->read;
        $cb->(map { +{ path => $_->fullname } } @events);
    };
}

sub wait_fsevents {
    require IO::Select;
    my $obj = shift;
    my @path = @_;

    my $fs;
    if ($obj->{detail} > 0) {
        $fs = _full_scan(@path);
    }
    my $sel = IO::Select->new;

    my %events;
    for my $path (@path) {
        my $fsevents = Mac::FSEvents->new({ path => $path, latency => $obj->{latency} });
        my $fh = $fsevents->watch;
        $sel->add($fh);
        $events{fileno $fh} = $fsevents;
    }

    return sub {
        my $cb = shift;

        my @ready = $sel->can_read;
        my @events;
        for my $fh (@ready) {
            my $fsevents = $events{fileno $fh};
            my %uniq;
            my @path = grep !$uniq{$_}++, map { $_->path } $fsevents->read_events;
            if ($obj->{details} > 0) {
                my $new_fs = _full_scan(@path);
                my $old_fs = +{ map { ($_ => $fs->{$_}) } keys %$new_fs };
                _compare_fs($old_fs, $new_fs, sub { push @events, { path => $_[0] } });
                $fs->{$_} = $new_fs->{$_} for keys %$new_fs;
            } else {
                push(@events,map { { path => $_ } } @path);
            }
            last if @events;
        }

        $cb->(@events);
    };
}

sub wait_timer {
    my $obj = shift;
    my @path = @_;

    my $fs = _full_scan(@path);

    return sub {
        my $cb = shift;
        my @events;
        while (1) {
            sleep $obj->{latency};
            my $new_fs = _full_scan(@path);
            _compare_fs($fs, $new_fs, sub { push @events, { path => $_[0] } });
            $fs = $new_fs;
            last if @events;
        };
        $cb->(@events);
    };
}

sub _compare_fs {
    my($old, $new, $cb) = @_;

    for my $dir (keys %$old) {
        for my $path (keys %{$old->{$dir}}) {
            if (!exists $new->{$dir}{$path}) {
                $cb->($path); # deleted
            } elsif (!$new->{$dir}{$path}{is_dir} &&
                    ( $old->{$dir}{$path}{mtime} != $new->{$dir}{$path}{mtime} ||
                      $old->{$dir}{$path}{size}  != $new->{$dir}{$path}{size})) {
                $cb->($path); # updated
            }
        }
    }

    for my $dir (keys %$new) {
        for my $path (sort grep { !exists $old->{$dir}{$_} } keys %{$new->{$dir}}) {
            $cb->($path); # new
        }
    }
}

sub _full_scan {
    my @path = @_;
    require File::Find;

    my %map;
    for my $path (@path) {
        my $fp = eval { Cwd::realpath($path) } or next;
        File::Find::finddepth({
            wanted => sub {
                my $fullname = $File::Find::fullname || File::Spec->rel2abs($File::Find::name);
                $map{Cwd::realpath($File::Find::dir)}{$fullname} = _stat($fullname);
            },
            follow_fast => 1,
            follow_skip => 2,
            no_chdir => 1,
        }, @path);

        # remove root entry
        delete $map{$fp}{$fp};
    }

    return \%map;
}

sub _stat {
    my $path = shift;
    my @stat = stat $path;
    return { path => $path, mtime => $stat[9], size => $stat[7], is_dir => -d _ };
}


1;
__END__

=encoding utf-8

=for stopwords

=head1 NAME

Filesys::Notify::Simple - Simple and dumb file system watcher

=head1 SYNOPSIS

  use Filesys::Notify::Simple;

  my $watcher = Filesys::Notify::Simple->new([ "." ]);
  $watcher->wait(sub {
      for my $event (@_) {
          $event->{path} # full path of the file updated
      }
  });

=head1 DESCRIPTION

Filesys::Notify::Simple is a simple but unified interface to get
notifications of changes to a given filesystem path. It utilizes
inotify2 on Linux and fsevents on OS X if they're installed, with a
fallback to the full directory scan if they're not available.

There are some limitations in this module. If you don't like it, use
L<File::ChangeNotify>.

=over 4

=item *

There is no file name based filter. Do it in your own code.

=item *

You can not get types of events (created, updated, deleted).

=item *

Currently C<wait> method blocks.

=back

In return, this module doesn't depend on any non-core
modules. Platform specific optimizations with L<Linux::Inotify2> and
L<Mac::FSEvents> are truely optional.

=head1 CONSTRUCTOR

=over 4

=item new ( [ @dirs ], opt1 => val1, ... )

Creates a new filesystem monitor.  C<@dirs> is a list of directories
to monitor, given as an array reference.  Additional named parameters
can be passed after that, including:

=over 4

=item Detail

Set to 1 (the default) or higher to get a notification for each change
to the filesystem with the full path to each changed file.  Set to 0
to get just a notification of some change to the monitored
directories, without information about individual changes.  Note that
if the individual changes have been detected already, they may be sent.

=item Latency

Requested time to wait between notifications, in seconds.  The default
is 2 seconds.  This is advisory, and you may get notifications more or
less frequently than this.

=item Method

Method to use to monitor for changes.  The default is to auto-detect
the most efficient method based on your OS and installed modules.
Values are:

=over 4

=item timer

Periodically scan the entire filesystem for changes.  See the
C<Latency> option to control how often files are checked.

=item inotify2

Use Linux inotify, version 2.  Requires L<Linux::Inotify2>.

=item fsevent

Use MacOS X FS Events.  Requires L<Mac::FSEvents>.

=back

=back

=back

=head1 METHODS

=over 4

=item wait ( &notify_sub )

Callback sub which should be called whenever a modified file is
changed.  It will be passed a single parameter containing an array
reference; each item in the array is a hash reference with the
following values:

=over 4

=item path

The path of the file that changed, or the monitored directory if
C<Detail> was set to 0 in the constructor.

=back

=back

=head1 AUTHOR

Tatsuhiko Miyagawa E<lt>miyagawa@bulknews.netE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<File::ChangeNotify> L<Mac::FSEvents> L<Linux::Inotify2>

=cut
