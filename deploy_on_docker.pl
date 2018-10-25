#!/usr/bin/env perl -w
#
# Author: dim.chernenko@gmail.com
#
# TODO: config files, build from docker image
#

use strict;

use warnings;

use Data::Dumper;
use Eixo::Docker::Api;
use File::Basename;
use Getopt::Long;
use POSIX qw/strftime/;
use Sys::Hostname;

our($Debug)	= 0;

our($ProgName)	= basename($0);

our($Usage)	= sprintf("Usage: %s -m ( health_check | deploy ) [ --name ServiceName ] [ --image repository/image:version ] [ -p 80 ] [ --hostPort 80 ] [ --hostIP 0.0.0.0 ] [ --cmd command ] [ --tlsverify --tlsBaseDir=/path/to/cert --tlscacert=ca.pem --tlscert=cert.pem --tlskey=key.pem ] [ -H HostName:Port ]  [ -l LogFile ] [ -d Debug ]\n", $ProgName);

$Usage	.= <<END

Examples of use:

./deploy_on_docker.pl -m deploy --image "tutum/hello-world" --cmd "ls -lrt" -p 80 --hostPort 80 -H "127.0.0.1:1234" -d

./deploy_on_docker.pl -m deploy --image "trafex/alpine-nginx-php7" --name "php7" -p 80 --hostPort 8100 -H "127.0.0.1:1234" 

./deploy_on_docker.pl -m deploy --image "ubuntu:14.04" --name "ubuntu" -p 80 --hostPort 81 -H "127.0.0.1:1234"

Secure connection
./deploy_on_docker.pl -m deploy --tlsverify --image "tutum/hello-world" --cmd "ls -lrt" -p 80 --hostPort 80 -H "192.168.0.170:2376" -d

END
;

# Usefull defaults -> TODO use config file
#

our($DateTime)		= strftime('%Y-%m-%d %H:%M:%S',localtime);
our($BaseDir)		= dirname($0);
our($HostName)          = hostname;
our($RemoteHostPort)	= "";
our($RemoteHostIP)	= "0.0.0.0";
our($DockerEndpoint)	= "127.0.0.1:4243";
our($LogFile)		= "${BaseDir}/logs/${ProgName}.log";

our($Mode)		= "health_check";

our($ServiceName)	= "";
our($DockerImage)	= "";
our($DockerImageTag)	= "";
our($ImagePorts)	= "";
our($RemoteCmd)		= "";

our($TLS_Verify)	= 0;
our($TLS_CertBaseDir)	= "${BaseDir}/crt/";
our($TLS_cacert)	= "${TLS_CertBaseDir}/ca.pem";
our($TLS_cert)		= "${TLS_CertBaseDir}/cert.pem";
our($TLS_key)		= "${TLS_CertBaseDir}/key.pem";

our($DockerDaemon);


# Parse Arguments
#
sub ParseArguments {

	if(scalar(@ARGV) == 0){
		printf(STDERR "%s", $Usage);
		exit 1; 
	}

	&GetOptions(
		"help|?" => sub {  
			printf(STDERR "%s", $Usage);
			exit 1; 
		},

		"-m=s"		=> \$Mode,

		"--name=s"	=> \$ServiceName,
		"--image=s"	=> \$DockerImage,
		"-p=s"		=> \$ImagePorts,
		"--hostPort=s"	=> \$RemoteHostPort,
		"--hostIp=s"	=> \$RemoteHostIP,
		"--cmd=s"	=> \$RemoteCmd,

		"tlsverify"	=> \$TLS_Verify,
		"tlsBaseDir=s"	=> \$TLS_CertBaseDir,	
		"tlscacert=s"	=> \$TLS_cacert,
		"tlscert=s"	=> \$TLS_cert,
		"tlskey=s"	=> \$TLS_key,

		"-H=s"		=> \$DockerEndpoint,

		"-d"		=> \$Debug,
	)
	or die("Error in command line arguments\n"); 

	if($TLS_Verify){
		if(length($TLS_cacert) == 0 || (! -f $TLS_cacert)){
			printf(STDERR "ERR_TLS101: %s\n", "When --tlsverify option is set path to --tlscacert \"${TLS_cacert}\" should exist and be accesible.");
			exit 1;
		}
		if(length($TLS_cert) == 0 || (! -f $TLS_cert)){
			printf(STDERR "ERR_TLS102: %s\n", "When --tlsverify option is set path to --tlscert \"${TLS_cert}\" should exist and be accesible.");
			exit 1;
		}
		if(length($TLS_key) == 0 || (! -f $TLS_key)){
			printf(STDERR "ERR_TLS103: %s\n", "When --tlsverify option is set path to --tlskey \"${TLS_key}\" should exist and be accesible.");
			exit 1;
		}
	}

	if(length($Mode) == 0 || $Mode !~ /(?:health_check|deploy)/){
		printf(STDERR "ERR_MDE110: %s\n", "Empty or incorrect Mode option -m \"${Mode}\" should be one of ( health_check | deploy ) .");
		exit 1;
	}
	elsif($Mode eq "deploy"){
		if(length($DockerImage) == 0){
			printf(STDERR "ERR_DPL111: %s\n", "Empty or incorrect deploy Mode option --image \"${DockerImage}\".");
			exit 1;		
		}

		$DockerImageTag = (split /\:/, $DockerImage)[1] || "";
	}

	if(length($DockerEndpoint) == 0){
		printf(STDERR "ERR_DKR111: %s\n", "Empty or incorrect Mode option -H \"${DockerEndpoint}\" should be correct docker endpoint format '127.0.0.1:4243' .");
		exit 1;
	}

	return 1;

}#End of ParseArguments


sub Init {

	eval{
		$DockerDaemon = Eixo::Docker::Api->new(
			host		=> $DockerEndpoint, 
			tls_verify	=> $TLS_Verify,
			ca_file		=> $TLS_cacert, 
			cert_file	=> $TLS_cert, 
			key_file	=> $TLS_key, 
		);
	};

	if ($@) {
		print Dumper($@);
		exit 1;
	}

	return 1;

}# End of Init


sub CleanUp {

	return 1;

}# End of CleanUp


sub PrintAndLog {

my($PAL_MsgId, $PAL_MsgText, $PAL_Log) = @_;

	if(! open(ptrLogFile, ">>", $PAL_Log)){
		printf(STDERR "ERR_LOG120: %s\n", "Failed to open LogFile for writing \"${PAL_Log}\". $!.");
		exit 1;
	}

	if($PAL_MsgId =~ /(?:ERR|FAT)/){
		printf(STDERR "%s: %s\n", $PAL_MsgId, $PAL_MsgText);
		printf(ptrLogFile "%s: %s\n", $PAL_MsgId, $PAL_MsgText);
	}
	elsif($PAL_MsgId =~ /(?:MSG)/){
		if($Debug){
			printf(STDOUT "%s: %s\n", $PAL_MsgId, $PAL_MsgText);
		}
		printf(ptrLogFile "%s: %s\n", $PAL_MsgId, $PAL_MsgText);
	}
	else{
		if($Debug){
			printf(STDOUT "%s", $PAL_MsgText);
		}
		printf(ptrLogFile "%s", $PAL_MsgText);
	}
	
	if(! close(ptrLogFile)){
		printf(STDERR "ERR_LOG120: %s\n", "Failed to close LogFile handle \"${PAL_Log}\". $!.");
		exit 1;
	}

	return 1;
}

# ----------------------------
# Main Code starts here
# ----------------------------

my($DebugMsg);

&ParseArguments();

&Init();

$DebugMsg =  <<END
----------------------------------
HostName: $HostName
DateTime: $DateTime

----------------------------------
Base Dir:\t$BaseDir
Log File:\t$LogFile

DockerEndpoint -->$DockerEndpoint<--

Mode:\t\t$Mode

TLS_Verify:\t\t$TLS_Verify
TLS_CertBaseDir:\t$TLS_CertBaseDir
TLS_cacert:\t\t$TLS_cacert
TLS_cert:\t\t$TLS_cert
TLS_key:\t\t$TLS_key
---------------------------------
END
;

&PrintAndLog("", $DebugMsg, $LogFile);

if($Mode eq "health_check"){
	# CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS              PORTS                      NAMES
	# 6b051f2d1c1f        bobrik/socat        "socat TCP-LISTEN:..."   10 hours ago        Up 2 minutes        127.0.0.1:1234->1234/tcp   youthful_hamilton
	#
	$DebugMsg = sprintf("%-20s\t%-20s\t%-20s\t%-20s\t%-20s\t%-25s\t%-25s\n", "CONTAINER ID", "IMAGE", "COMMAND", "CREATED", "STATUS", "PORTS", "NAMES");

	for my $DockerContainer ( @{$DockerDaemon->containers->getAll()} ){	
		if(defined($DockerContainer->Id)){
			$DebugMsg .= sprintf("%-20s\t%-20s\t%-20s\t%-20s\t%-20s\t%-25s\t%-25s\n", 
				defined($DockerContainer->Id) ? substr($DockerContainer->Id, 0, 12) : "", 
				defined($DockerContainer->Image) ? $DockerContainer->Image : "", 
				defined($DockerContainer->Command) ? substr($DockerContainer->Command,0,19) : "", 
				defined($DockerContainer->Created) ? $DockerContainer->Created : "", 
				defined($DockerContainer->Status) ? $DockerContainer->Status : "", 
				defined($DockerContainer->Ports) ? "${$DockerContainer->Ports}[0]->{IP}:${$DockerContainer->Ports}[0]->{PublicPort}\-\>${$DockerContainer->Ports}[0]->{PrivatePort}\/${$DockerContainer->Ports}[0]->{Type}" : "", 
				defined($DockerContainer->Names) ? (join ",",@{$DockerContainer->Names}) : ""
			);
		}
	}

	$Debug	= 1;

	&PrintAndLog("", $DebugMsg, $LogFile);
}
elsif($Mode eq "deploy"){

$DebugMsg =  <<END
---------------------------------
-- DEPLOY --
---------------------------------
ServiceName    :\t$ServiceName
DockerImage    :\t$DockerImage
DockerImageTag :\t$DockerImageTag
ImagePorts     :\t$ImagePorts
RemoteCmd      :\t$RemoteCmd
RemoteHostIP   :\t$RemoteHostIP
RemoteHostPort :\t$RemoteHostPort
---------------------------------
END
;

	&PrintAndLog("", $DebugMsg, $LogFile);

	my $image;
	my $container;

	eval {
		$image = $DockerDaemon->images->get(id => $DockerImage);
	};

	my $ImageLoaded = 1;

	if ($@) {
		&PrintAndLog("MSG", "No such image! We will try to fetch from registry.", $LogFile);
		$ImageLoaded = 0;
	}

	if(! $ImageLoaded){

			eval{
				$image = $DockerDaemon->images->create( 
								fromImage=> length($DockerImageTag) > 0 ? (split /\:/, $DockerImage)[0] : $DockerImage,
								tag=>$DockerImageTag,
		   						onSuccess=>sub {
											&PrintAndLog("MSG", "FINISHED", $LogFile);     
								},
								onProgress=>sub{
											&PrintAndLog("MSG", $_[0], $LogFile);
										}	
				);
			};

			if ($@) {
                		&PrintAndLog("ERR", Dumper($@), $LogFile);
			}
	}

	my(@CmdArr) 	= split(/\s/, $RemoteCmd);

	&PrintAndLog("MSG", "Create container.", $LogFile);

	eval {
		$container = $DockerDaemon->containers->create(
			Hostname => 'test',
			tag=> $DockerImageTag,
			Image => $DockerImage,
			Name => $ServiceName,
			NetworkDisabled => \0,
			Cmd => \@CmdArr,
			ExposedPorts => {
				"$ImagePorts/tcp" =>  {}
			},
			HostConfig => {
				"PortBindings" => { "$ImagePorts/tcp" => [{"HostIp" => $RemoteHostIP, "HostPort" => $RemoteHostPort }] },
			},
		);
	};

	if ($@) {
                &PrintAndLog("ERR", Dumper($@), $LogFile);
		exit 1;
	}

	if(length($ServiceName) > 0){
		eval{
			$container = $DockerDaemon->containers->getByName($ServiceName);
		};

		if ($@) {
			&PrintAndLog("ERR", Dumper($@), $LogFile);
			exit 1;
		}
	}

	eval{
		$container->start(
			"PortBindings" => { "$ImagePorts/tcp"=> [{"HostPort" => $ImagePorts }] },
		);
	};

	if ($@) {
		&PrintAndLog("ERR", Dumper($@), $LogFile);
		exit 1;
	}
 
	print STDOUT "Container ID: $container->{Id}\n";

	my $output_callback;

	eval{
		$output_callback = $container->attach(
			stdout=>1,
			stderr => 1,
			stdin=>0,
			stream=>0,
			logs => 1,
		);
	};

	if ($@) {
		&PrintAndLog("ERR", Dumper($@), $LogFile);
		exit 1;
	}

	print STDOUT 'Container log: '.$output_callback->();
}

# close files, remove tmp files, etc
#

&PrintAndLog("MSG", "CleanUp.", $LogFile);

&CleanUp();

&PrintAndLog("MSG", "Completed.", $LogFile);

#EOF
