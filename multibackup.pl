#!/usr/bin/perl
#
# Multiple Instances of Percona MySQL Backup
# Copyright (c) 2015 Alexey Baikov <sysboss[@]mail.ru>
#
# Limitations: All instances should have same credentials

use strict;
use warnings;

use Getopt::Long;
use File::Lockfile;
use File::Slurp;
use Config::Tiny;

my $archives_limit = 2;
my $mysql_user     = 'root';
my $mysql_pass     = 'password';
my $dump_dir       = '/backups';
my $lockdir        = '/var/run/mysqld/';
my $my_cnf_file    = '/etc/mysql/my.cnf';
my $backup_args    = '--compress --compress-threads 4';
my @config         = ();
my $dry_run;

sub usage {
    print << "_END_USAGE";
usage: $0 [ options ] FROM

Options:
  -h|--help                Usage (this info)
  --dry-run                Dry run mode

_END_USAGE

    exit 0;
}

GetOptions(
    'v|verbose' => \$verbose,
    'dry-run'   => \$dry_run,
) || usage();

# verifications
chomp(my $innobackupex = `which innobackupex`);

die "No innobackupex tool found"
    if ! $innobackupex;

die "my.cnf file not found at $my_cnf_file"
    if ! -e $my_cnf_file;

opendir my $rundir, $lockdir
    or die "Cannot open run directory: $!";

# Sanitize my.cnf config
foreach my $line ( read_file( $my_cnf_file ) ){
    next if $line =~ /^#/;
    next if $line =~ /^pager/;

    if( $line !~ /.*=.*/ ){
        next if $line !~ /^\[/;
    }

    push @config, $line;
}

write_file("/tmp/backup_my.cfg", @config);

# Read sanitized my.cnf
my $conf     = Config::Tiny->read("/tmp/backup_my.cfg");
my @pidfiles = readdir $rundir;

foreach my $pid (@pidfiles){
    next if $pid !~ m/(mysqld([0-9]{1,3}))\.pid$/;

    my $cnf_file   = Config::Tiny->new;
    my $lockfile   = File::Lockfile->new($pid, $lockdir);
    my $instance   = $1;
    my $group      = $2;
    my $socketfile = "${lockdir}${instance}.sock";

    print " * Instance: $instance\n";

    # verify instance is running
    print "   - NOT RUNNING" and next
        if ! $lockfile->check;

    # generate config
    print "No config found in $my_cnf_file for mysqld$group\n" and next
        if ! $conf->{"mysqld$group"};

    print "   - Starting backup\n";

    # rotate backups
    if( ! -d "$dump_dir/$instance" ){
        mkdir "$dump_dir/$instance";
    } else {
        opendir my $dir, "$dump_dir/$instance"
            or die "Cannot open directory: $!";

        my @backups = sort grep { $_ !~ /\./ } readdir $dir;

        if( @backups > $archives_limit ){
            unless( @backups == $archives_limit ){
                my $old = shift( @backups );

                # delete older backups
                system("rm -fr $dump_dir/$instance/$old")
                    if "$dump_dir/$instance" ne '/';
        }}

        closedir $dir;
    }

    # create separate my.cnf for each instance
    $cnf_file->{'mysqld'} = $conf->{"mysqld$group"};
    $cnf_file->write("/tmp/my$group.cfg");

    print "   - Doing backup.... dry-run\n\n" and next
        if $dry_run;

    my $command = "$innobackupex $backup_args" .
                  " --user=$mysql_user --password=$mysql_pass" .
                  " --socket=$socketfile --defaults-file=/tmp/my$group.cfg" .
                  " --rsync $dump_dir/$instance";

    # run innobackupex
    `$command`;

    if( $? eq 0 ){
        print "\nBackup succeeded\n\n";
    } else {
        print "\nBackup failed\n\n";
    }
}

closedir $rundir;