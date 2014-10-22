package Sys::Info::Driver::Linux::OS;
use strict;
use vars qw( $VERSION );
use base qw( Sys::Info::Base );
use POSIX ();
use Cwd;
use Carp qw( croak );
use Sys::Info::Driver::Linux;
use Sys::Info::Constants qw( :linux );

$VERSION = '0.69_01';

my %OSVERSION; # cache

my %DISTROFIX = qw( suse SUSE );

my $EDITION   = {
    #�taken from wikipedia
    ubuntu => {
        '4.10' => 'Warty Warthog',
        '5.04' => 'Hoary Hedgehog',
        '5.10' => 'Breezy Badger',
        '6.06' => 'Dapper Drake',
        '6.10' => 'Edgy Eft',
        '7.04' => 'Feisty Fawn',
        '7.10' => 'Gutsy Gibbon',
        '8.04' => 'Hardy Heron',
        '8.10' => 'Intrepid Ibex',
    },
};

my $MANUFACTURER = {
    #�taken from wikipedia
    ubuntu    => 'Canonical Ltd. / Ubuntu Foundation',
    centos    => 'Lance Davis',
    fedora    => 'Fedora Project',
    debian    => 'Debian Project',
    mandriva  => 'Mandriva',
    knoppix   => 'Klaus Knopper',
    gentoo    => 'Gentoo Foundation',
    suse      => 'Novell',
    slackware => 'Patrick Volkerding',
};

my %DEBIAN_VFIX = (
    # we get the version as "lenny/sid" for example
    buzz   => '1.1',
    rex    => '1.2',
    bo     => '1.3',
    hamm   => '2.0',
    slink  => '2.1',
    potato => '2.2',
    woody  => '3.0',
    sarge  => '3.1',
    etch   => '4.0',
    lenny  => '5.0',
);

my $EDITION_SUPPORT      = join '|', keys %{ $EDITION      };
my $MANUFACTURER_SUPPORT = join '|', keys %{ $MANUFACTURER };

# unimplemented
sub logon_server {}

sub edition {
    my $self = shift->_populate_osversion;
    $OSVERSION{RAW}->{EDITION};
}

sub tz {
    my $self = shift;
    return if ! -e proc->{timezone};
    chomp( my $rv = $self->slurp( proc->{timezone} ) );
    return $rv;
}

sub meta {
    my $self = shift;
    $self->_populate_osversion();

    my $manufacturer = $OSVERSION{NAME} =~ m{ ($MANUFACTURER_SUPPORT) }xmsi
                     ? $MANUFACTURER->{ lc $1 }
                     : undef;

    require POSIX;
    require Sys::Info::Device;

    my $cpu   = Sys::Info::Device->new('CPU');
    my $arch  = ($cpu->identify)[0]->{architecture};
    my %mem   = $self->_parse_meminfo;
    my @swaps = $self->_parse_swap;
    my %info;

    $info{manufacturer}              = $manufacturer;
    $info{build_type}                = undef;
    $info{owner}                     = undef;
    $info{organization}              = undef;
    $info{product_id}                = undef;
    $info{install_date}              = $OSVERSION{RAW}->{BUILD_DATE};
    $info{boot_device}               = undef;

    $info{physical_memory_total}     = $mem{MemTotal};
    $info{physical_memory_available} = $mem{MemFree};
    $info{page_file_total}           = $mem{SwapTotal};
    $info{page_file_available}       = $mem{SwapFree};

    # windows specific
    $info{windows_dir}               = undef;
    $info{system_dir}                = undef;

    $info{system_manufacturer}       = undef;
    $info{system_model}              = undef;
    $info{system_type}               = sprintf "%s based Computer", $arch;

    $info{page_file_path}            = join ', ', map { $_->{Filename} } @swaps;

    return %info;
}

sub tick_count {
    my $self = shift;
    my $uptime = $self->slurp( proc->{uptime} ) || return 0;
    my @uptime = split /\s+/, $uptime;
    # this file has two entries. uptime is the first one. second: idle time
    return $uptime[LIN_UP_TIME];
}

sub name {
    my $self = shift->_populate_osversion;
    my %opt  = @_ % 2 ? () : (@_);
    my $id   = $opt{long} ? ($opt{edition} ? 'LONGNAME_EDITION' : 'LONGNAME')
             :              ($opt{edition} ? 'NAME_EDITION'     : 'NAME'    )
             ;
    return $OSVERSION{ $id };
}


sub version   { shift->_populate_osversion(); return $OSVERSION{VERSION}      }
sub build     { shift->_populate_osversion(); return $OSVERSION{RAW}->{BUILD_DATE} }
sub uptime    {                               return time - shift->tick_count }

# user methods
sub is_root {
    return 0 if defined &Sys::Info::EMULATE;
    my $name = login_name();
    my $id   = POSIX::geteuid();
    my $gid  = POSIX::getegid();
    return 0 if $@;
    return 0 if ! defined($id) || ! defined($gid);
    return $id == 0 && $gid == 0 && $name eq 'root';
}

sub login_name {
    my $self  = shift;
    my %opt   = @_ % 2 ? () : (@_);
    my $login = POSIX::getlogin() || return;
    my $rv    = eval { $opt{real} ? (getpwnam $login)[LIN_REAL_NAME_FIELD] : $login };
    $rv =~ s{ [,]{3,} \z }{}xms if $opt{real};
    return $rv;
}

sub node_name { (POSIX::uname())[LIN_NODENAME] }

sub domain_name {
    my $self = shift;
    my $domain;
    #�hmmmm...
    foreach my $line ( $self->read_file( proc->{resolv} ) ) {
        chomp $line;
        if ( $line =~ m{\A domain \s+ (.*) \z}xmso ) {
            $domain = $1;
            last;
        }
    }
    return $domain;
}

sub fs {
    my $self = shift;
    $self->{current_dir} = Cwd::getcwd();

    my(@fstab, @junk, $re);
    foreach my $line( $self->read_file( proc->{fstab} ) ) {
        chomp $line;
        next if $line =~ m[^#];
        @junk = split /\s+/, $line;
        next if ! @junk || @junk != 6;
        next if lc($junk[LIN_FS_TYPE]) eq 'swap'; # ignore swaps
        $re = $junk[LIN_MOUNT_POINT];
        next if $self->{current_dir} !~ m{\Q$re\E}i;
        push @fstab, [ $re, $junk[LIN_FS_TYPE] ];
    }

    @fstab  = sort( { $b->[0] cmp $a->[0] } @fstab ) if @fstab > 1;
    my $fstype = $fstab[0]->[1];
    my $attr   = $self->_fs_attributes( $fstype );
    return(
        filesystem => $fstype,
        ($attr ? %{$attr} : ())
    );
}

# ------------------------[ P R I V A T E ]------------------------ #

sub _parse_meminfo {
    my $self = shift;
    my %mem;
    foreach my $line ( split /\n/, $self->slurp( proc->{meminfo} ) ) {
        chomp $line;
        my($k, $v) = split /:/, $line;
        #�units in KB
        $mem{ $k } = (split /\s+/, $self->trim( $v ) )[0];
    }
    return %mem;
}

sub _parse_swap {
    my $self = shift;
    my @swaps      = split /\n/, $self->slurp( proc->{swaps} );
    my @swap_title = split /\s+/, shift( @swaps );
    my @swap_list;
    foreach my $line ( @swaps ) {
        chomp $line;
        my @data = split /\s+/, $line;
        push @swap_list,
            {
                map { $swap_title[$_] => $data[$_] } 0..$#swap_title
            };
    }
    return @swap_list;
}

sub _ip {
    my $self = shift;
    my $raw  = qx(ifconfig);
    return if not $raw;
    my @raw = split /inet addr/, $raw;
    if ( $raw[1] =~ m{(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})}xmso ) {
        return $1;
    }
    return;
}

sub _populate_osversion {
    return if %OSVERSION;
    my $self    = shift;
    my $version = '';

    if (  -e proc->{'version'} && -f _) {
        $version =  $self->trim(
                        $self->slurp(
                            proc->{'version'},
                            'I can not open linux version file %s for reading: '
                        )
                    );
    }

    my($str, $build_date) = split /\#/, $version;
    my($kernel, $distro)  = ('','');
    #$build_date = "1 Fri Jul 23 20:48:29 CDT 2004';";
    #$build_date = "1 SMP Mon Aug 16 09:25:06 EDT 2004";
    $build_date = '' if not $build_date; # running since blah thingie
    # format: 'Linux version 1.2.3 (foo@bar.com)'
    # format: 'Linux version 1.2.3 (foo@bar.com) (gcc 1.2.3)'
    # format: 'Linux version 1.2.3 (foo@bar.com) (gcc 1.2.3 (Redhat blah blah))'
    if ( $str =~ LIN_RE_LINUX_VERSION ) {
        $kernel = $1;
        if ( $distro = $self->trim( $2 ) ) {
            if ( $distro =~ m{ \s\((.+?)\)\) \z }xms ) {
                $distro = $1;
            }
        }
    }

    $distro = 'Linux' if not $distro or $distro =~ m{\(gcc};

    # kernel build date
    $build_date = $self->date2time($build_date) if $build_date;
    my $build = $build_date || '';
    $build = scalar( localtime $build ) if $build;

    require Linux::Distribution;
    my $linux = Linux::Distribution->new;
    my($dn, $dv);
    if ( $dn = $linux->distribution_name ) {
        $dn  = $DISTROFIX{$dn} || ucfirst $dn;
        $dn .= ' Linux';
        $dv  = $linux->distribution_version;
    }

    my $V      = $dv || $kernel;
    my $osname = $dn || $distro;

    my $edition;
    if ( $osname =~ m{ ($EDITION_SUPPORT) }xmsi ) {
        my $id = lc $1;
        $edition = $EDITION->{ $id }{ $V };
    }

    if ( ! $edition && $dv !~ m{[0-9]}xms ) {
        if ( $dn =~ /Debian/i ) {
            my @buf = split m{/}, $dv;
            if ( my $test = $DEBIAN_VFIX{ lc $buf[0] } ) {
                # Debian version comes as the edition name
                $edition = $dv;
                $V       = $dv = $test;
            }
        }
    }

    %OSVERSION = (
        NAME             => $osname,
        NAME_EDITION     => $edition ? "$osname ($edition)" : $osname,
        LONGNAME         => '', # will be set below
        LONGNAME_EDITION => '', # will be set below
        VERSION  => $V,
        KERNEL   => $kernel,
        RAW      => {
                        BUILD      => defined $build      ? $build      : 0,
                        BUILD_DATE => defined $build_date ? $build_date : 0,
                        EDITION    => $edition,
                    },
    );

    $OSVERSION{LONGNAME}         = sprintf "%s %s (kernel: %s)",
                                   @OSVERSION{ qw/ NAME         VERSION / },
                                   $kernel;
    $OSVERSION{LONGNAME_EDITION} = sprintf "%s %s (kernel: %s)",
                                   @OSVERSION{ qw/ NAME_EDITION VERSION / },
                                   $kernel;
    return;
}

sub _fs_attributes {
    my $self = shift;
    my $fs   = shift;
    my $_PC_PATH_MAX;

    return {
        ext3 => {
                case_sensitive     => 1, #'supports case-sensitive filenames',
                preserve_case      => 1, #'preserves the case of filenames',
                unicode            => 1, #'supports Unicode in filenames',
                #acl                => '', #'preserves and enforces ACLs',
                #file_compression   => '', #'supports file-based compression',
                #disk_quotas        => '', #'supports disk quotas',
                #sparse             => '', #'supports sparse files',
                #reparse            => '', #'supports reparse points',
                #remote_storage     => '', #'supports remote storage',
                #compressed_volume  => '', #'is a compressed volume (e.g. DoubleSpace)',
                #object_identifiers => '', #'supports object identifiers',
                efs                => '1', #'supports the Encrypted File System (EFS)',
                #max_file_length    => '';
        },
    }->{$fs};
}

1;

__END__

=head1 NAME

Sys::Info::Driver::Linux::OS - Linux backend

=head1 SYNOPSIS

-

=head1 DESCRIPTION

-

=head1 METHODS

Please see L<Sys::Info::OS> for definitions of these methods and more.

=head2 build

=head2 domain_name

=head2 edition

=head2 fs

=head2 is_root

=head2 login_name

=head2 logon_server

=head2 meta

=head2 name

=head2 node_name

=head2 tick_count

=head2 tz

=head2 uptime

=head2 version

=head1 SEE ALSO

L<Sys::Info>, L<Sys::Info::OS>,
The C</proc> virtual filesystem:
L<http://www.redhat.com/docs/manuals/linux/RHL-9-Manual/ref-guide/s1-proc-topfiles.html>.

=head1 AUTHOR

Burak G�rsoy, E<lt>burakE<64>cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2006-2009 Burak G�rsoy. All rights reserved.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify 
it under the same terms as Perl itself, either Perl version 5.8.8 or, 
at your option, any later version of Perl 5 you may have available.

=cut

#------------------------------------------------------------------------------#

sub _fetch_user_info {
    my %user;
    $user{NAME}               = POSIX::getlogin();
    $user{REAL_USER_ID}       = POSIX::getuid();  # $< uid
    $user{EFFECTIVE_USER_ID}  = POSIX::geteuid(); # $> effective uid
    $user{REAL_GROUP_ID}      = POSIX::getgid();  # $( guid
    $user{EFFECTIVE_GROUP_ID} = POSIX::getegid(); # $) effective guid
    my %junk;
    #�quota, comment & expire are unreliable
    @junk{qw(name  passwd  uid  gid
             quota comment gcos dir shell expire)} = getpwnam($user{NAME});
    $user{REAL_NAME} = defined $junk{gcos}    ? $junk{gcos}    : '';
    $user{COMMENT}   = defined $junk{comment} ? $junk{comment} : '';
    return %user;
}


