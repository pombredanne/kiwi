#!/usr/bin/perl
#================
# FILE          : kiwi.pl
#----------------
# PROJECT       : openSUSE Build-Service
# COPYRIGHT     : (c) 2012 SUSE LINUX Products GmbH, Germany
#               :
# AUTHOR        : Marcus Schaefer <ms@suse.de>
#               :
# BELONGS TO    : Operating System images
#               :
# DESCRIPTION   : This is the main script to provide support
#               : for creating operating system images
#               :
#               :
# STATUS        : $LastChangedBy: ms $
#               : $LastChangedRevision: 1 $
#----------------
use lib './modules','/usr/share/kiwi/modules';
use strict;

#============================================
# perl debugger setup
#--------------------------------------------
# $DB::inhibit_exit = 0;

#============================================
# Modules
#--------------------------------------------
use warnings;
use Carp qw (cluck);
use Getopt::Long;
use File::Basename;
use File::Spec;
use File::Find;
use File::Glob ':glob';
use JSON;

#==========================================
# KIWIModules
#------------------------------------------
use KIWIAnalyseSystem;
use KIWIAnalyseReport;
use KIWIAnalyseTemplate;
use KIWIAnalyseSoftware;
use KIWIBoot;
use KIWICache;
use KIWICommandLine;
use KIWIFilesystemOptions;
use KIWIGlobals;
use KIWIImage;
use KIWIImageCreator;
use KIWIImageFormat;
use KIWILocator;
use KIWILog;
use KIWIQX;
use KIWIRoot;
use KIWIResult;
use KIWIRuntimeChecker;
use KIWIXML;
use KIWIXMLInfo;
use KIWIXMLRepositoryData;
use KIWIXMLValidator;

#============================================
# UTF-8 for output to stdout
#--------------------------------------------
binmode(STDOUT, ":encoding(UTF-8)");

#============================================
# Globals
#--------------------------------------------
my $kiwi    = KIWILog -> instance();
my $global  = KIWIGlobals -> instance();
my $locator = KIWILocator -> instance();

#============================================
# Variables (operation mode)
#--------------------------------------------
my $kic;        # Image preparation / creation
my $icache;     # Image Cache creation
my $cmdL;       # Command line data container

#==========================================
# IPC; signal setup
#------------------------------------------
local $SIG{"HUP"}  = \&quit;
local $SIG{"TERM"} = \&quit;
local $SIG{"INT"}  = \&quit;

#==========================================
# main
#------------------------------------------
sub main {
    # ...
    # This is the KIWI project to prepare and build operating
    # system images from a given installation source. The system
    # will create a chroot environment representing the needs
    # of a XML control file. Once prepared KIWI can create several
    # OS image types.
    # ---
    #========================================
    # store caller information
    #----------------------------------------
    $kiwi -> loginfo ("kiwi @ARGV\n");
    $kiwi -> loginfo ("kiwi revision: ".revision()."\n");
    #==========================================
    # Initialize and check options
    #------------------------------------------
    init();
    #==========================================
    # Check for nocolor option
    #------------------------------------------
    if ($cmdL -> getNoColor()) {
        $kiwi -> info ("Switching off colored output\n");
        if (! $kiwi -> setColorOff ()) {
            kiwiExit (1);
        }
    }
    #==========================================
    # remove pre-defined smart channels
    #------------------------------------------
    if (glob ("/etc/smart/channels/*")) {
        KIWIQX::qxx ( "rm -f /etc/smart/channels/*" );
    }
    #========================================
    # Bundle user relevant build results
    #----------------------------------------
    if ($cmdL->getOperationMode("bundle")) {
        my $bundle = KIWIResult -> new (
            $cmdL -> getOperationMode("bundle"),
            $cmdL -> getImageTargetDir(),
            $cmdL -> getBuildNumber()
        );
        if (! $bundle) {
            kiwiExit (1);
        }
        if (! $bundle -> buildRelease()) {
            kiwiExit (1);
        }
        if (! $bundle -> populateRelease()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #========================================
    # Prepare and Create in one step
    #----------------------------------------
    if ($cmdL->getOperationMode("build")) {
        #==========================================
        # Create destdir if needed
        #------------------------------------------
        $cmdL -> setDefaultAnswer ("yes");
        my $dirCreated = $global -> createDirInteractive(
            $cmdL->getImageTargetDir()."/build", $cmdL->getDefaultAnswer()
        );
        if (! defined $dirCreated) {
            kiwiExit (1);
        }
        #==========================================
        # Setup prepare
        #------------------------------------------
        my $imageTarget = $cmdL -> getImageTargetDir();
        my $rootTarget  = $imageTarget.'/build/image-root';
        $cmdL -> setForceNewRoot (1);
        $cmdL -> setRootTargetDir ($rootTarget);
        $cmdL -> setOperationMode ("prepare", $cmdL->getConfigDir());
        mkdir $imageTarget;
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        my $selectedType = $kic -> getSelectedBuildType();
        if ($selectedType && $selectedType eq 'cpio') {
            if (! $kic -> prepareBootImage(
                $kic-> getSystemXML(),$rootTarget,$rootTarget
            )) {
                kiwiExit (1);
            }
        } else {
            if (! $kic -> prepareImage()) {
                kiwiExit (1);
            }
        }
        #==========================================
        # Setup create
        #------------------------------------------
        $cmdL -> setConfigDir ($rootTarget);
        $cmdL -> setOperationMode ("create",$rootTarget);
        $cmdL -> setForceNewRoot (0);
        $cmdL -> unsetRecycleRootDir();
        $kic  -> initialize();
        if ($selectedType && $selectedType eq 'cpio') {
            if (! $kic -> createBootImage(
                $kic-> getSystemXML(),$rootTarget,$imageTarget
            )) {
                kiwiExit (1);
            }
        } else {
            if (! $kic -> createImage()) {
                kiwiExit (1);
            }
        }
        kiwiExit (0);
    }

    #========================================
    # Create image cache(s)
    #----------------------------------------
    if ($cmdL->getOperationMode("initCache")) {
        #==========================================
        # Process system image description
        #------------------------------------------
        $kiwi -> info ("Reading image description [Cache]...\n");
        my $xml = KIWIXML -> new (
            $cmdL->getOperationMode("initCache"),
            undef,$cmdL->getBuildProfiles(),$cmdL,undef
        );
        if (! defined $xml) {
            kiwiExit (1);
        }
        my $pkgMgr = $cmdL -> getPackageManager();
        if ($pkgMgr) {
            $xml -> setPackageManager($pkgMgr);
        }
        #==========================================
        # Create cache(s)...
        #------------------------------------------
        my $gdata = $global -> getKiwiConfig();
        my $cdir = $cmdL->getCacheDir();
        if (! $cdir) {
            $cdir = $locator -> getDefaultCacheDir();
        }
        $icache = KIWICache -> new (
            $xml,$cdir,$gdata->{BasePath},
            $cmdL->getBuildProfiles(),
            $cmdL->getOperationMode("initCache"),
            $cmdL
        );
        if (! $icache) {
            kiwiExit (1);
        }
        my $cacheInit = $icache -> initializeCache (
            $cmdL,"create-cache"
        );
        if (! $cacheInit) {
            kiwiExit (1);
        }
        if (! $icache -> createCache ($cacheInit)) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #========================================
    # Prepare image and build chroot system
    #----------------------------------------
    if ($cmdL->getOperationMode("prepare")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        my $selectedType = $kic -> getSelectedBuildType();
        if ($selectedType && $selectedType eq 'cpio') {
            if (! $kic -> prepareBootImage(
                $kic -> getSystemXML(),
                $cmdL-> getRootTargetDir(),$cmdL-> getRootTargetDir()
            )) {
                kiwiExit (1);
            }
        } else {
            if (! $kic -> prepareImage()) {
                kiwiExit (1);
            }
        }
        kiwiExit (0);
    }

    #==========================================
    # Create image from chroot system
    #------------------------------------------
    if ($cmdL->getOperationMode("create")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        my $selectedType = $kic -> getSelectedBuildType();
        if ($selectedType && $selectedType eq 'cpio') {
            if (! $kic -> createBootImage(
                $kic -> getSystemXML(),
                $cmdL-> getConfigDir(),$cmdL-> getImageTargetDir()
            )) {
                kiwiExit (1);
            }
        } else {
            if (! $kic -> createImage()) {
                kiwiExit (1);
            }
        }
        kiwiExit (0);
    }

    #==========================================
    # Upgrade image in chroot system
    #------------------------------------------
    if ($cmdL->getOperationMode("upgrade")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> upgradeImage()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Analyse system and create description
    #------------------------------------------
    if ($cmdL->getOperationMode("analyse")) {
        $kiwi -> info ("Starting system analysis\n");
        my $destination = $cmdL->getOperationMode("analyse");
        $destination = "/var/cache/kiwi/describe/".$destination;
        my $system = KIWIAnalyseSystem -> new (
            $destination,$cmdL
        );
        if (! $system) {
            kiwiExit (1);
        }
        if (! $system -> createCustomDataSyncReference()) {
            kiwiExit (1);
        }
        if (! $system -> syncCustomData()) {
            kiwiExit (1);
        }
        $kiwi -> info ("Creating base description files\n");
        my $software = KIWIAnalyseSoftware -> new (
            $system,$cmdL
        );
        if (! $software) {
            kiwiExit (1);
        }
        my $template = KIWIAnalyseTemplate -> new (
            $destination,$cmdL,$system,$software
        );
        if (! $template) {
            kiwiExit (1);
        }
        $template -> writeKIWIXMLConfiguration();
        $template -> writeKIWIScripts();
        $kiwi -> info ("Creating system report\n");
        my $report = KIWIAnalyseReport -> new (
            $destination,$cmdL,$system,$software
        );
        if (! $report) {
            kiwiExit (1);
        }
        $report -> createReport();
        if (! $system -> commitTransaction()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # setup a splash initrd
    #------------------------------------------
    if ($cmdL->getOperationMode("setupSplash")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createSplash()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create a boot Stick (USB)
    #------------------------------------------
    if ($cmdL->getOperationMode("bootUSB")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageBootUSB()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create a boot CD (ISO)
    #------------------------------------------
    if ($cmdL->getOperationMode("bootCD")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageBootCD()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create an install CD (ISO)
    #------------------------------------------
    if ($cmdL->getOperationMode("installCD")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageInstallCD()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create an install USB stick
    #------------------------------------------
    if ($cmdL->getOperationMode("installStick")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageInstallStick()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create an install PXE data set
    #------------------------------------------
    if ($cmdL->getOperationMode("installPXE")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageInstallPXE()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Create a virtual disk image
    #------------------------------------------
    if ($cmdL->getOperationMode("bootVMDisk")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageDisk()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Convert image into format/configuration
    #------------------------------------------
    if ($cmdL->getOperationMode("convert")) {
        $kic = KIWIImageCreator -> new ($cmdL);
        if (! $kic) {
            kiwiExit (1);
        }
        if (! $kic -> createImageFormat()) {
            kiwiExit (1);
        }
        kiwiExit (0);
    }

    #==========================================
    # Test suite
    #------------------------------------------
    if ($cmdL->getOperationMode("testImage")) {
        $kiwi -> info ("Starting image test run...");
        my $suite  = "/usr/lib/os-autoinst";
        my $distri = "kiwi-$$";
        my $type   = $cmdL -> getBuildType();
        my $image  = $cmdL -> getOperationMode("testImage");
        my $tcase  = $cmdL -> getTestCase();
        #==========================================
        # Check pre-conditions
        #------------------------------------------
        if (! -d $suite) {
            $kiwi -> failed ();
            $kiwi -> error ("Required os-autoinst test-suite not installed");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        if (! -f $image) {
            $kiwi -> failed ();
            $kiwi -> error ("Test image $image doesn't exist");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        if (! defined $type) {
            $kiwi -> failed ();
            $kiwi -> error ("No test image type specified");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        if (! defined $tcase) {
            $kiwi -> failed ();
            $kiwi -> error ("No test test case specified");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        if (! -d $tcase."/".$type) {
            $kiwi -> failed ();
            $kiwi -> error ("Test case for type $type does not exist");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        if (! -f $tcase."/env.sh") {
            $kiwi -> failed ();
            $kiwi -> error ("Can't find environment for this test");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        #==========================================
        # Turn parameters into absolute pathes
        #------------------------------------------
        $image = File::Spec->rel2abs ($image);
        $tcase = File::Spec->rel2abs ($tcase);
        #==========================================
        # Create distri link for os-autoinst
        #------------------------------------------
        my $test = $tcase."/".$type;
        my $data = KIWIQX::qxx ("ln -s $test $suite/distri/$distri 2>&1");
        my $code = $? >> 8;
        if ($code != 0) {
            $kiwi -> failed ();
            $kiwi -> error  ("Can't create distri link: $data");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        #==========================================
        # Create result mktemp directory
        #------------------------------------------
        my $out = KIWIQX::qxx ("mktemp -q -d /tmp/kiwi-testrun-XXXXXX 2>&1");
        $code = $? >> 8; chomp $out;
        if ($code != 0) {
            $kiwi -> error  ("Couldn't create result directory: $out: $!");
            $kiwi -> failed ();
            KIWIQX::qxx ("rm -f $suite/distri/$distri");
            kiwiExit (1);
        }
        KIWIQX::qxx ("chmod 755 $out 2>&1");
        #==========================================
        # Copy environment to result directory
        #------------------------------------------
        $data = KIWIQX::qxx ("cp $tcase/env.sh $out");
        $code = $? >> 8;
        if ($code != 0) {
            $kiwi -> failed ();
            $kiwi -> error  ("Failed to copy test environment: $data");
            $kiwi -> failed ();
            KIWIQX::qxx ("rm -f $suite/distri/$distri");
            KIWIQX::qxx ("rm -rf $out");
            kiwiExit (1);
        }
        #==========================================
        # Create call file
        #------------------------------------------
        if (open my $FD,'>',"$out/run.sh") {
            print $FD "cd $out\n";
            print $FD "export DISTRI=$distri"."\n";
            print $FD "export ISO=$image"."\n";
            print $FD 'isotovideo $ISO'."\n";
            close $FD;
        } else {
            $kiwi -> failed ();
            $kiwi -> error  ("Failed to create run test script: $!");
            $kiwi -> failed ();
            KIWIQX::qxx ("rm -f $suite/distri/$distri");
            KIWIQX::qxx ("rm -rf $out");
            kiwiExit (1);
        }
        #==========================================
        # Create screen ctrl file
        #------------------------------------------
        if (open my $FD,'>',"$out/run.ctrl") {
            print $FD "logfile /dev/null\n";
            close $FD;
        } else {
            $kiwi -> failed ();
            $kiwi -> error  ("Failed to create screen ctrl file: $!");
            $kiwi -> failed ();
            KIWIQX::qxx ("rm -f $suite/distri/$distri");
            KIWIQX::qxx ("rm -rf $out");
            kiwiExit (1);
        }
        #==========================================
        # Call the test
        #------------------------------------------
        $kiwi -> done ();
        $kiwi -> info ("Calling isotovideo, this can take some time...\n");
        $kiwi -> info ("watch the screen session by: 'screen -r'");
        KIWIQX::qxx ("chmod u+x $out/run.sh");
        KIWIQX::qxx ("screen -L -D -m -c $out/run.ctrl $out/run.sh");
        $code = $? >> 8;
        KIWIQX::qxx ("rm -f $suite/distri/$distri");
        if ($code == 0) {
            $kiwi -> done ();
        } else {
            $kiwi -> failed ();
        }
        $kiwi -> info ("Find test results in $out");
        $kiwi -> done ();
        #==========================================
        # Read result
        #------------------------------------------
        my $json;
        foreach my $result (glob ("$out/testresults/*/results.json")) {
            my $json_fd = FileHandle -> new();
            if ($json_fd -> open ($result)) {
                local $/;
                my $json_text = <$json_fd>;
                $json = from_json(
                    $json_text, { utf8  => 1 }
                );
                $json_fd -> close();
            }
            last;
        }
        #==========================================
        # Exit according to test result
        #------------------------------------------
        if ($json) {
            my $status = $json->{overall};
            if ($status eq 'fail') {
                $kiwi -> info ("Test Failed");
                $kiwi -> done();
                kiwiExit (1);
            } else {
                $kiwi -> info ("Test Succeeded");
                $kiwi -> failed();
                kiwiExit (0);
            }
        }
    }
    return 1;
}

#==========================================
# init
#------------------------------------------
sub init {
    # ...
    # initialize, check privilege and options. KIWI
    # requires you to perform at least one action.
    # An action is either to prepare or create an image
    # ---
    #==========================================
    # Option variables
    #------------------------------------------
    my $Help;
    my $ArchiveImage;          # archive image results into a tarball
    my $FSBlockSize;           # filesystem block size
    my $FSInodeSize;           # filesystem inode size
    my $FSJournalSize;         # filesystem journal size
    my $FSMaxMountCount;       # filesystem (ext) max mount count between checks
    my $FSCheckInterval;       # filesystem (ext) max interval between fs checks
    my $FSInodeRatio;          # filesystem bytes/inode ratio
    my $SetImageType;          # set image type to use, default is primary type
    my $Build;                 # run prepare and create in one step
    my $Prepare;               # control XML file for building chroot extend
    my $Create;                # image description for building image extend
    my $InitCache;             # create image cache(s) from given description
    my $Upgrade;               # upgrade physical extend
    my $BootVMDisk;            # deploy initrd booting from a VM
    my $InstallCD;             # Installation initrd booting from CD
    my $BootCD;                # Boot initrd booting from CD
    my $BootUSB;               # Boot initrd booting from Stick
    my $TestImage;             # call end-to-end testsuite if installed
    my $InstallStick;          # Installation initrd booting from USB stick
    my $SetupSplash;           # setup kernel splash screen
    my $Analyse;               # inspect running system and create a description
    my $Convert;               # convert image into given format/configuration
    my $MBRID;                 # custom mbrid value
    my @RemovePackage;         # remove pack by adding them to the remove list
    my $IgnoreRepos;           # ignore repositories specified so far
    my $SetRepository;         # set first repo for building physical extend
    my $SetRepositoryType;     # set firt repository type
    my $SetRepositoryAlias;    # alias name for the repository
    my $SetRepositoryPriority; # priority for the repository
    my @AddRepository;         # add repository for building physical extend
    my @AddRepositoryType;     # add repository type
    my @AddRepositoryAlias;    # alias name for the repository
    my @AddRepositoryPriority; # priority for the repository
    my @AddPackage;            # add packages to the image package list
    my @AddPattern;            # add patterns to the image package list
    my $Partitioner;           # default partitioner
    my $ListXMLInfo;           # list XML information
    my $CheckConfig;           # Configuration file to check
    my $CreateInstSource;      # create installation source from meta packages
    my $CreateHash;            # create .checksum.md5 for given description
    my $CreatePassword;        # create crypted password
    my $Clone;                 # clone existing image description
    my $InstallCDSystem;       # disk system image to be installed on disk
    my $TestCase;              # path to image description including test/ case
    my $InstallStickSystem;    # disk system image to be installed on disk
    my $InstallPXE;            # Installation initrd booting via network
    my $InstallPXESystem;      # disk system image to be installed on disk
    my @Profiles;              # list of profiles to include in image
    my $ForceBootstrap;        # force bootstrap, checked for recycle-root mode
    my $ForceNewRoot;          # force creation of new root directory
    my $NoColor;               # don't use colored output (done/failed messages)
    my $GzipCmd;               # command to run to gzip things
    my $TargetStudio;          # command to run to create on demand storage
    my $Verbosity;             # control the verbosity level
    my $TargetArch;            # target architecture -> writes zypp.conf
    my $Debug;                 # activates the internal stack trace output
    my $Format;                # format to convert to, vmdk, ovf, etc...
    my $defaultAnswer;         # default answer to any questions
    my $targetDevice;          # alternative device instead of a loop device
    my $ImageCache;            # build an image cache for later re-use
    my $RecycleRoot;           # use existing root directory incl. contents
    my $Destination;           # destination directory for logical extends
    my $LogFile;               # optional file name for logging
    my @ListXMLInfoSelection;  # info selection for listXMLInfo
    my $RootTree;              # optional root tree destination
    my $BootVMSystem;          # system image to be copied on a VM disk
    my $BootVMSize;            # size of virtual disk
    my $BundleBuild;           # bundle user relevant build results
    my $BundleID;              # bundle/build id used in bundle-build
    my $StripImage;            # strip shared objects and binaries
    my $PrebuiltBootImage;     # dir. where a prepared boot image may be found
    my $ISOCheck;              # create checkmedia boot entry
    my $CheckKernel;           # check if kernel matches in boot and system img
    my $LVM;                   # use LVM partition setup for virtual disk
    my $GrubChainload;         # install grub loader in first partition not MBR
    my $FatStorage;            # size of fat partition if syslinux is used
    my $DiskStartSector;       # location of start sector (default is 2048)
    my $EditBootConfig;        # allow to run script before bootloader install
    my $EditBootInstall;       # allow to run script after bootloader install
    my $PackageManager;        # package manager to use
    my $DiskAlignment;         # partition alignment, default is 4096 KB
    my $DiskBIOSSectorSize;    # sector size default is 512 bytes
    my $Version;               # version information
    #==========================================
    # create logger and cmdline object
    #------------------------------------------
    $cmdL = KIWICommandLine -> new ();
    if (! $cmdL) {
        kiwiExit (1);
    }
    my $gdata = $global -> getKiwiConfig();
    #==========================================
    # get options and call non-root tasks
    #------------------------------------------
    my $result = GetOptions(
        "archive-image"         => \$ArchiveImage,
        "add-package=s"         => \@AddPackage,
        "add-pattern=s"         => \@AddPattern,
        "add-profile=s"         => \@Profiles,
        "add-repo=s"            => \@AddRepository,
        "add-repoalias=s"       => \@AddRepositoryAlias,
        "add-repopriority=i"    => \@AddRepositoryPriority,
        "add-repotype=s"        => \@AddRepositoryType,
        "bundle-build=s"        => \$BundleBuild,
        "bundle-id=s"           => \$BundleID,
        "bootcd=s"              => \$BootCD,
        "bootusb=s"             => \$BootUSB,
        "bootvm=s"              => \$BootVMDisk,
        "bootvm-disksize=s"     => \$BootVMSize,
        "bootvm-system=s"       => \$BootVMSystem,
        "build|b=s"             => \$Build,
        "cache=s"               => \$ImageCache,
        "check-config=s"        => \$CheckConfig,
        "check-kernel"          => \$CheckKernel,
        "clone|o=s"             => \$Clone,
        "convert=s"             => \$Convert,
        "create|c=s"            => \$Create,
        "create-instsource=s"   => \$CreateInstSource,
        "createhash=s"          => \$CreateHash,
        "createpassword"        => \$CreatePassword,
        "debug"                 => \$Debug,
        "del-package=s"         => \@RemovePackage,
        "destdir|d=s"           => \$Destination,
        "fat-storage=i"         => \$FatStorage,
        "force-bootstrap"       => \$ForceBootstrap,
        "force-new-root"        => \$ForceNewRoot,
        "format|f=s"            => \$Format,
        "fs-blocksize=i"        => \$FSBlockSize,
        "fs-check-interval=i"   => \$FSCheckInterval,
        "fs-inoderatio=i"       => \$FSInodeRatio,
        "fs-inodesize=i"        => \$FSInodeSize,
        "fs-journalsize=i"      => \$FSJournalSize,
        "fs-max-mount-count=i"  => \$FSMaxMountCount,
        "edit-bootconfig=s"     => \$EditBootConfig,
        "edit-bootinstall=s"    => \$EditBootInstall,
        "grub-chainload"        => \$GrubChainload,
        "gzip-cmd=s"            => \$GzipCmd,
        "help|h"                => \$Help,
        "ignore-repos"          => \$IgnoreRepos,
        "info|i=s"              => \$ListXMLInfo,
        "init-cache=s"          => \$InitCache,
        "installcd=s"           => \$InstallCD,
        "installcd-system=s"    => \$InstallCDSystem,
        "installstick=s"        => \$InstallStick,
        "installstick-system=s" => \$InstallStickSystem,
        "installpxe=s"          => \$InstallPXE,
        "installpxe-system=s"   => \$InstallPXESystem,
        "isocheck"              => \$ISOCheck,
        "list|l"                => \&listImage,
        "logfile=s"             => \$LogFile,
        "lvm"                   => \$LVM,
        "mbrid=o"               => \$MBRID,
        "describe=s"            => \$Analyse,
        "nocolor"               => \$NoColor,
        "package-manager=s"     => \$PackageManager,
        "partitioner=s"         => \$Partitioner,
        "prebuiltbootimage=s"   => \$PrebuiltBootImage,
        "prepare|p=s"           => \$Prepare,
        "recycle-root"          => \$RecycleRoot,
        "root|r=s"              => \$RootTree,
        "select=s"              => \@ListXMLInfoSelection,
        "set-repo=s"            => \$SetRepository,
        "set-repoalias=s"       => \$SetRepositoryAlias,
        "set-repopriority=i"    => \$SetRepositoryPriority,
        "set-repotype=s"        => \$SetRepositoryType,
        "setup-splash=s"        => \$SetupSplash,
        "strip|s"               => \$StripImage,
        "target-arch=s"         => \$TargetArch,
        "targetdevice=s"        => \$targetDevice,
        "targetstudio=s"        => \$TargetStudio,
        "type|t=s"              => \$SetImageType,
        "upgrade|u=s"           => \$Upgrade,
        "test-image=s"          => \$TestImage,
        "test-case=s"           => \$TestCase,
        "disk-start-sector=i"   => \$DiskStartSector,
        "disk-alignment=i"      => \$DiskAlignment,
        "disk-sector-size=i"    => \$DiskBIOSSectorSize,
        "verbose|v=i"           => \$Verbosity,
        "version"               => \$Version,
        "yes|y"                 => \$defaultAnswer,
    );
    #==========================================
    # Check result of options parsing
    #------------------------------------------
    if ( $result != 1 ) {
        usage(1);
    }
    #========================================
    # set logfile if defined at the cmdline
    #----------------------------------------
    if ($LogFile) {
        if ($InitCache) {
            # when cache init runs logging should happen on the console
            $LogFile = "terminal";
        }
        $cmdL -> setLogFile($LogFile);
        $kiwi -> info ("Setting log file to: $LogFile\n");
        if (! $kiwi -> setLogFile ( $LogFile )) {
            kiwiExit (1);
        }
    }
    #========================================
    # set sector size for alignment
    #----------------------------------------
    $cmdL -> setDiskBIOSSectorSize (
        $DiskBIOSSectorSize
    );
    #========================================
    # set partition alignment
    #----------------------------------------
    $cmdL -> setDiskAlignment (
        $DiskAlignment
    );
    #========================================
    # set start sector for disk images
    #----------------------------------------
    if (! $DiskStartSector) {
        $DiskStartSector = int (
            $cmdL -> getDiskAlignment * 1024 / $cmdL -> getDiskBIOSSectorSize()
        );
        my $defaultStartSector = $gdata -> {DiskStartSector};
        if ($DiskStartSector < $defaultStartSector) {
            $DiskStartSector = $defaultStartSector;
        }
    }
    $cmdL -> setDiskStartSector (
        $DiskStartSector
    );
    #========================================
    # set list of filesystem options
    #----------------------------------------
    my %init = (
        blocksize     => $FSBlockSize,
        checkinterval => $FSCheckInterval,
        inodesize     => $FSInodeSize,
        inoderatio    => $FSInodeRatio,
        journalsize   => $FSJournalSize,
        maxmountcnt   => $FSMaxMountCount
    );
    my $fsOpts = KIWIFilesystemOptions -> new(\%init);
    if (! $fsOpts) {
        kiwiExit (1);
    }
    my $status = $cmdL -> setFilesystemOptions ($fsOpts);
    if (! $status)  {
        kiwiExit (1);
    }
    #========================================
    # check if bundle-build option is set
    #----------------------------------------
    if (defined $BundleID) {
        $cmdL -> setBuildNumber ($BundleID);
    }
    #========================================
    # check if archive-image option is set
    #----------------------------------------
    if (defined $ArchiveImage) {
        $cmdL -> setArchiveImage ($ArchiveImage);
    }
    #========================================
    # check if edit-bootconfig option is set
    #----------------------------------------
    if (defined $EditBootConfig) {
        $cmdL -> setEditBootConfig ($EditBootConfig);
    }
    #========================================
    # check if edit-bootinstall option is set
    #----------------------------------------
    if (defined $EditBootInstall) {
        $cmdL -> setEditBootInstall ($EditBootInstall);
    }
    #========================================
    # check if fat-storage option is set
    #----------------------------------------
    if (defined $FatStorage) {
        $cmdL -> setFatStorage ($FatStorage);
    }
    #========================================
    # check if grub-chainload option is set
    #----------------------------------------
    if (defined $GrubChainload) {
        $cmdL -> setGrubChainload ($GrubChainload);
    }
    #========================================
    # check if lvm option is set
    #----------------------------------------
    if (defined $LVM) {
        $cmdL -> setLVM ($LVM);
    }
    #========================================
    # check if check-kernel option is set
    #----------------------------------------
    if (defined $CheckKernel) {
        $cmdL -> setCheckKernel ($CheckKernel);
    }
    #========================================
    # check if isocheck option is set
    #----------------------------------------
    if (defined $ISOCheck) {
        $cmdL -> setISOCheck ($ISOCheck);
    }
    #========================================
    # check if prebuilt boot path is set
    #----------------------------------------
    if (defined $PrebuiltBootImage) {
        $cmdL -> setPrebuiltBootImagePath ($PrebuiltBootImage);
    }
    #========================================
    # check if strip image option is set
    #----------------------------------------
    if (defined $StripImage) {
        $cmdL -> setStripImage ($StripImage);
    }
    #========================================
    # check if XML Info Selection is set
    #----------------------------------------
    if (@ListXMLInfoSelection) {
        $cmdL -> setXMLInfoSelection (\@ListXMLInfoSelection);
    }
    #========================================
    # check if TestCase is specified
    #----------------------------------------
    if (defined $TestCase) {
        $cmdL -> setTestCase ($TestCase);
    }
    #========================================
    # check if Debug is specified
    #----------------------------------------
    if (defined $Debug) {
        $cmdL -> setDebug ($Debug);
    }
    #========================================
    # check if NoColor is specified
    #----------------------------------------
    if (defined $NoColor) {
        $cmdL -> setNoColor ($NoColor);
    }
    #========================================
    # check if MBRID is specified
    #----------------------------------------
    if (defined $MBRID) {
        if ($MBRID < 0 || $MBRID > 0xffffffff) {
            $kiwi -> error ("Invalid mbrid");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        $cmdL -> setMBRID (sprintf ("0x%08x", $MBRID));
    }
    #========================================
    # check if default answer is specified
    #----------------------------------------
    if (defined $defaultAnswer) {
        $cmdL -> setDefaultAnswer ($defaultAnswer);
    }
    #========================================
    # check if initrd needs to be stored
    #----------------------------------------
    if (defined $SetupSplash) {
        $cmdL -> setInitrdFile ($SetupSplash);
    }
    if (defined $BootUSB) {
        $cmdL -> setInitrdFile ($BootUSB);
    }
    if (defined $BootCD) {
        $cmdL -> setInitrdFile ($BootCD);
    }
    if (defined $InstallCD) {
        $cmdL -> setInitrdFile ($InstallCD);
    }
    if (defined $InstallStick) {
        $cmdL -> setInitrdFile ($InstallStick);
    }
    if (defined $InstallPXE) {
        $cmdL -> setInitrdFile ($InstallPXE);
    }
    if (defined $BootVMDisk) {
        $cmdL -> setInitrdFile ($BootVMDisk);
    }
    #========================================
    # check if system loc. needs to be stored
    #----------------------------------------
    if (defined $InstallCDSystem) {
        $cmdL -> setSystemLocation ($InstallCDSystem);
    }
    if (defined $InstallStickSystem) {
        $cmdL -> setSystemLocation ($InstallStickSystem);
    }
    if (defined $InstallPXESystem) {
        $cmdL -> setSystemLocation ($InstallPXESystem);
    }
    if (defined $BootVMSystem) {
        $cmdL -> setSystemLocation ($BootVMSystem);
    }
    if (defined $Convert) {
        $cmdL -> setSystemLocation ($Convert);
    }
    #========================================
    # check if image format is specified
    #----------------------------------------
    if (defined $Format) {
        $cmdL -> setImageFormat ($Format);
    }
    #========================================
    # check if disk size needs to be stored
    #----------------------------------------
    if (defined $BootVMSize) {
        $cmdL -> setImageDiskSize ($BootVMSize);
    }
    #========================================
    # check if targetdevice is specified
    #----------------------------------------
    if (defined $targetDevice) {
        my $status = $cmdL -> setImageTargetDevice ($targetDevice);
        if (! $status) {
            kiwiExit(1);
        }
    }
    #========================================
    # check if packages are to be added
    #----------------------------------------
    if (@AddPackage) {
        $cmdL -> setAdditionalPackages (\@AddPackage);
    }
    #========================================
    # check if patterns are to be added
    #----------------------------------------
    if (@AddPattern) {
        $cmdL -> setAdditionalPatterns (\@AddPattern);
    }
    #========================================
    # check if packs are marked for removal
    #----------------------------------------
    if (@RemovePackage) {
        $cmdL -> setPackagesToRemove (\@RemovePackage)
    }
    #========================================
    # check if repositories are to be added
    #----------------------------------------
    if (@AddRepository) {
        my $numRepos = scalar @AddRepository;
        my $numTypes = scalar @AddRepositoryType;
        my $numAlia  = scalar @AddRepositoryAlias;
        my $numPrio  = scalar @AddRepositoryPriority;
        my $msg;
        if (($numAlia) && ($numRepos != $numAlia)) {
            $msg = 'Must specify repository alias for each given ';
            $msg.= 'repository. Mismatch number of arguments.';
        }
        if (($numPrio) && ($numRepos != $numPrio)) {
            $msg = 'Must specify repository priority for each given ';
            $msg.= 'repository. Mismatch number of arguments.';
        }
        if (($numTypes) && ($numRepos != $numTypes)) {
            $msg = 'Must specify repository type for each given ';
            $msg.= 'repository. Mismatch number of arguments.';
        }
        if ($msg) {
            $kiwi -> error($msg);
            $kiwi -> failed();
            kiwiExit (1);
        }
        my $idx = 0;
        my @reposToAdd;
        while ($idx < $numRepos) {
            my %init = (
                path => $AddRepository[$idx],
                type => $AddRepositoryType[$idx]
            );
            if ($idx < $numAlia) {
                $init{alias} = $AddRepositoryAlias[$idx];
            }
            if ($idx < $numPrio) {
                $init{priority} = $AddRepositoryPriority[$idx];
            }
            my $repo = KIWIXMLRepositoryData -> new (\%init);
            if (! $repo) {
                kiwiExit (1);
            }
            push @reposToAdd, $repo;
            $idx += 1;
        }
        my $res = $cmdL -> setAdditionalRepos(\@reposToAdd);
        if (! $res) {
            kiwiExit (1);
        }
    }
    #========================================
    # check if force-bootstrap is set
    #----------------------------------------
    if (defined $ForceBootstrap) {
        $cmdL -> setForceBootstrap ($ForceBootstrap);
    }
    #========================================
    # check if force-new-root is set
    #----------------------------------------
    if (defined $ForceNewRoot) {
        $cmdL -> setForceNewRoot ($ForceNewRoot);
    }
    #========================================
    # check if repositories are to be ignored
    #----------------------------------------
    if (defined $IgnoreRepos) {
        $cmdL -> setIgnoreRepos(1);
    }
    #========================================
    # check for specified cache location
    #----------------------------------------
    if (defined $ImageCache) {
        $cmdL -> setCacheDir($ImageCache);
    }
    #========================================
    # check if a package manager is specified
    #----------------------------------------
    if (defined $PackageManager) {
        my $result = $cmdL -> setPackageManager ($PackageManager);
        if (! $result) {
            kiwiExit (1);
        }
    }
    #========================================
    # check replacement repo information
    #----------------------------------------
    if ($SetRepository) {
        my %init = (
            alias    => $SetRepositoryAlias,
            path     => $SetRepository,
            priority => $SetRepositoryPriority,
            type     => $SetRepositoryType
        );
        my $repo = KIWIXMLRepositoryData -> new(\%init);
        if (! $repo) {
            kiwiExit (1);
        }
        my $result = $cmdL -> setReplacementRepo($repo);
        if (! $result) {
            kiwiExit (1);
        }
    }
    #========================================
    # check if recycle-root is used
    #----------------------------------------
    if (defined $RecycleRoot) {
        $cmdL -> setRootRecycle();
    }
    #============================================
    # check if a target arch is defined
    #--------------------------------------------
    if (defined $TargetArch) {
        $cmdL -> setImageArchitecture ($TargetArch);
        $kiwi -> warning ("--target-arch option set:\n".
            "  This option influences the behavior of zypper\n".
            "  Thus it has no effect on other package managers !\n".
            "  This option is used to force the installation of packages\n".
            "  for a specific architecture and is not the right choice when\n".
            "  a complete image should be build for a specific architecture\n".
            "  Building 32bit images on a 64bit host should be done by\n".
            "  prefixing the kiwi call with 'linux32'. Cross building\n".
            "  images for other architectures requires a build root\n".
            "  environment of the target architecture and a virtualization\n".
            "  layer handling the binary format. The qemu-binfmt-conf.sh\n".
            "  and the openSUSE buildservice tool osc helps you here\n"
        );
    }
    #============================================
    # check if a partitioner is used
    #--------------------------------------------
    if ($Partitioner) {
        if (($Partitioner ne "parted") &&($Partitioner ne "fdasd")) {
            $kiwi -> error ("Invalid partitioner, expected parted|fdasd");
            $kiwi -> failed ();
            kiwiExit (1);
        }
        $cmdL -> setPartitioner ($Partitioner);
    }
    #============================================
    # check Partitioner according to device
    #-----------------------------------------
    if (($targetDevice) && ($targetDevice =~ /\/dev\/dasd/)) {
        $cmdL -> setPartitioner ("fdasd");
    }
    #========================================
    # turn destdir into absolute path
    #----------------------------------------
    if (defined $Destination) {
        $Destination = File::Spec->rel2abs ($Destination);
        $cmdL -> setImageTargetDir ($Destination);
    }
    if (defined $Prepare) {
        if (($Prepare !~ /^\//) && (! -d $Prepare)) {
            $Prepare = $gdata->{System}."/".$Prepare;
        }
        $Prepare =~ s/\/$//;
    }
    if (defined $Create) {
        if (($Create !~ /^\//) && (! -d $Create)) {
            $Create = $gdata->{System}."/".$Create;
        }
        $Create =~ s/\/$//;
    }
    if (defined $Build) {
        if (($Build !~ /^\//) && (! -d $Build)) {
            $Build = $gdata->{System}."/".$Build;
        }
        $Build =~ s/\/$//;
    }
    if (defined $InitCache) {
        if (($InitCache !~ /^\//) && (! -d $InitCache)) {
            $InitCache = $gdata->{System}."/".$InitCache;
        }
        $InitCache =~ s/\/$//;
    }
    if (defined $ListXMLInfo) {
        if (($ListXMLInfo !~ /^\//) && (! -d $ListXMLInfo)) {
            $ListXMLInfo = $gdata->{System}."/".$ListXMLInfo;
        }
        $ListXMLInfo =~ s/\/$//;
    }
    #========================================
    # store uniq path to image description
    #----------------------------------------
    if (defined $Prepare) {
        $cmdL -> setConfigDir ($Prepare);
    }
    if (defined $Upgrade) {
        $cmdL -> setConfigDir ($Upgrade);
    }
    if (defined $Create) {
        $cmdL -> setConfigDir ($Create);
    }
    if (defined $Build) {
        $cmdL -> setConfigDir ($Build);
    }
    if (defined $InitCache) {
        $cmdL -> setConfigDir ($InitCache);
    }
    #========================================
    # store operation modes
    #----------------------------------------
    if (defined $BundleBuild) {
        $cmdL -> setOperationMode ("bundle",$BundleBuild);
    }
    if (defined $Build) {
        $cmdL -> setOperationMode ("build",$Build);
    }
    if (defined $Prepare) {
        $cmdL -> setOperationMode ("prepare",$Prepare);
    }
    if (defined $Upgrade) {
        $cmdL -> setOperationMode ("upgrade",$Upgrade);
    }
    if (defined $Create) {
        $cmdL -> setOperationMode ("create",$Create);
    }
    if (defined $InitCache) {
        $cmdL -> setOperationMode ("initCache",$InitCache);
    }
    if (defined $Analyse) {
        $cmdL -> setOperationMode ("analyse",$Analyse);
    }
    if (defined $SetupSplash) {
        $cmdL -> setOperationMode ("setupSplash",$SetupSplash);
    }
    if (defined $BootUSB) {
        $cmdL -> setOperationMode ("bootUSB",$BootUSB);
    }
    if (defined $BootCD) {
        $cmdL -> setOperationMode ("bootCD",$BootCD);
    }
    if (defined $InstallCD) {
        $cmdL -> setOperationMode ("installCD",$InstallCD);
    }
    if (defined $InstallStick) {
        $cmdL -> setOperationMode ("installStick",$InstallStick);
    }
    if (defined $InstallPXE) {
        $cmdL -> setOperationMode ("installPXE",$InstallPXE);
    }
    if (defined $BootVMDisk) {
        $cmdL -> setOperationMode ("bootVMDisk",$BootVMDisk);
    }
    if (defined $Convert) {
        $cmdL -> setOperationMode ("convert",$Convert);
    }
    if (defined $TestImage) {
        $cmdL -> setOperationMode ("testImage",$TestImage);
    }
    #========================================
    # store original value of Profiles
    #----------------------------------------
    $cmdL -> setBuildProfiles (\@Profiles);
    #========================================
    # set root target directory if given
    #----------------------------------------
    if (defined $RootTree) {
        $cmdL -> setRootTargetDir($RootTree)
    }
    #========================================
    # set default inode ratio for ext2/3
    #----------------------------------------
    if (! defined $FSInodeRatio) {
        $FSInodeRatio = 16384;
    }
    #========================================
    # set default inode size for ext2/3
    #----------------------------------------
    if (! defined $FSInodeSize) {
        $FSInodeSize = 256;
    }
    #========================================
    # set build type from commandline
    #----------------------------------------
    if (defined $SetImageType) {
        $cmdL -> setBuildType($SetImageType);
    }
    #==========================================
    # non root task: get XML information
    #------------------------------------------
    if (defined $ListXMLInfo) {
        getXMLInfo ($ListXMLInfo);
    }
    #==========================================
    # non root task: Check XML configuration
    #------------------------------------------
    if (defined $CheckConfig) {
        checkConfig ($CheckConfig);
    }
    #==========================================
    # non root task: Create crypted password
    #------------------------------------------
    if (defined $CreatePassword) {
        createPassword();
    }
    #========================================
    # non root task: create inst source
    #----------------------------------------
    if (defined $CreateInstSource) {
        createInstSource ($CreateInstSource,$Verbosity);
    }
    #==========================================
    # non root task: create md5 hash
    #------------------------------------------
    if (defined $CreateHash) {
        createHash ($CreateHash);
    }
    #==========================================
    # non root task: Clone image 
    #------------------------------------------
    if (defined $Clone) {
        cloneImage ($Clone);
    }
    #==========================================
    # non root task: Help
    #------------------------------------------
    if (defined $Help) {
        usage(0);
    }
    #==========================================
    # non root task: Version
    #------------------------------------------
    if (defined $Version) {
        version(0);
    }
    #==========================================
    # Check for root privileges
    #------------------------------------------
    if ($< != 0) {
        $kiwi -> error ("Only root can do this");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    #==========================================
    # Check option combination/values
    #------------------------------------------
    if (
        (! defined $Build)              &&
        (! defined $BundleBuild)        &&
        (! defined $Prepare)            &&
        (! defined $Create)             &&
        (! defined $InitCache)          &&
        (! defined $InstallCD)          &&
        (! defined $Upgrade)            &&
        (! defined $SetupSplash)        &&
        (! defined $BootVMDisk)         &&
        (! defined $Analyse)            &&
        (! defined $InstallStick)       &&
        (! defined $InstallPXE)         &&
        (! defined $ListXMLInfo)        &&
        (! defined $CreatePassword)     &&
        (! defined $BootCD)             &&
        (! defined $BootUSB)            &&
        (! defined $Clone)              &&
        (! defined $CheckConfig)        &&
        (! defined $TestImage)          &&
        (! defined $Convert)
    ) {
        $kiwi -> warning ("No operation specified");
        $kiwi -> skipped ();
        $kiwi -> info ("--> For building call:\n");
        $kiwi -> note ("\n\tkiwi --build <template> -d <destdir>\n\n");
        $kiwi -> info ("--> Looking up templates\n");
        listImage();
    }
    if (($Build) && ($RecycleRoot)) {
        $kiwi -> error (
            "Sorry --recycle-root can be only used in separate build steps"
        );
        $kiwi -> failed ();
        $kiwi -> error ("User --prepare and --create instead of --build");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if (($EditBootConfig) && (! -e $EditBootConfig)) {
        $kiwi -> error ("Boot config script $EditBootConfig doesn't exist");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if (($EditBootInstall) && (! -e $EditBootInstall)) {
        $kiwi -> error ("Boot config script $EditBootInstall doesn't exist");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if (($targetDevice) && (! -b $targetDevice)) {
        $kiwi -> error ("Target device $targetDevice doesn't exist");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if ((defined $IgnoreRepos) && (defined $SetRepository)) {
        $kiwi -> error ("Can't use ignore repos together with set repos");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if (defined $GzipCmd) {
        $kiwi -> info ("Setting gzip command to: $GzipCmd");
        $global -> setKiwiConfigData ("Gzip", $GzipCmd);
        $kiwi -> done ();
    }
    if (defined $TargetStudio) {
        $kiwi -> info ("Setting SuSE Studio storage creator to: $TargetStudio");
        $global -> setKiwiConfigData ("StudioNode", $TargetStudio);
        $kiwi -> done ();
    }
    if ((defined $BootVMDisk) && (! defined $BootVMSystem)) {
        $kiwi -> error ("Virtual Disk setup must specify a bootvm-system");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if ((defined $Build) && (! defined $Destination)) {
        $kiwi -> error  ("No destination directory specified");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if ((defined $BundleBuild) && (! defined $Destination)) {
        $kiwi -> error  ("No destination directory specified");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if ((defined $BundleBuild) && (! defined $BundleID)) {
        $kiwi -> error  ("No bundle ID specified for bundle build");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    return;
}

#==========================================
# usage
#------------------------------------------
sub usage {
    # ...
    # Explain the available options for this
    # image creation system
    # ---
    my $exit = shift;
    my $date = qx ( date -I ); chomp $date;
    print "Linux KIWI setup  (image builder) ($date)\n";
    print "Copyright (c) 2007 - SUSE LINUX Products GmbH\n";
    print "\n";

    print "Usage:\n";
    print "    kiwi -l | --list\n";
    print "\n";
    print "XML Configuration check:\n";
    print "    kiwi --check-config <path-to-xml-file-to-check>\n";
    print "\n";
    print "Image Description Cloning:\n";
    print "    kiwi -o | --clone <image-path> -d <destination>\n";
    print "\n";
    print "Image Creation in one step:\n";
    print "    kiwi -b | --build <image-path> -d <destination>\n";
    print "      [ --cache <dir> ]\n";
    print "\n";
    print "Image Preparation/Creation in two steps:\n";
    print "    kiwi -p | --prepare <image-path>\n";
    print "       [ --root <image-root> ]\n";
    print "       [ --recycle-root [ --force-bootstrap ]] ||\n";
    print "       [ --cache <dir> ]\n";
    print "    kiwi -c | --create  <image-root> -d <destination>\n";
    print "       [ --type <image-type> ]\n";
    print "       [ --recycle-root [ --force-bootstrap ]]\n";
    print "\n";
    print "Image Cache Creation:\n";
    print "    kiwi --init-cache <image-path>\n";
    print "       [ --cache <dir> ]\n";
    print "\n";
    print "Image Upgrade:\n";
    print "    kiwi -u | --upgrade <image-root>\n";
    print "       [ --add-package <name> --add-pattern <name> ]\n";
    print "\n";
    print "System Analysis:\n";
    print "    kiwi -D | --describe <name>\n";
    print "\n";
    print "Testsuite (requires os-autoinst package):\n";
    print "    kiwi --test-image <image> --test-case <path>\n";
    print "         --type <image-type>\n";
    print "\n";
    print "Image bundle (user relevant files)\n";
    print "    kiwi --bundle-build <image-dest> --bundle-id <build-number>\n";
    print "         --destdir <dest-dir>\n";
    print "\n";
    print "Image Post Creation modes:\n";
    print "    kiwi --bootvm <initrd> --bootvm-system <systemImage>\n";
    print "       [ --bootvm-disksize <size> ]\n";
    print "    kiwi --bootcd  <initrd>\n";
    print "    kiwi --bootusb <initrd>\n";
    print "    kiwi --installcd <initrd>\n";
    print "       [ --installcd-system <raw-system-image> ]\n";
    print "    kiwi --installstick <initrd>\n";
    print "       [ --installstick-system <raw-system-image> ]\n";
    print "    kiwi --installpxe <initrd>\n";
    print "       [ --installpxe-system <raw-system-image> ]\n";
    print "\n";
    print "Image Format Conversion:\n";
    print "    kiwi --convert <systemImage>\n";
    print "       [ --format <vmdk|vdi|ovf|qcow2|vhd|..> ]\n";
    print "\n";
    print "Helper Tools:\n";
    print "    kiwi --createpassword\n";
    print "    kiwi --createhash <image-path>\n";
    print "    kiwi --info <image-path> --select <\n";
    print "           repo-patterns|patterns|types|sources|\n";
    print "           size|profiles|packages|version\n";
    print "         > --select ...\n";
    print "    kiwi --setup-splash <initrd>\n";
    print "\n";
    print "Global Options:\n";
    print "    [ --add-profile <profile-name> ]\n";
    print "      Use the specified profile.\n";
    print "\n";
    print "    [ --set-repo <URL> --set-repotype <type> ]\n";
    print "      Set/Overwrite repo URL and type for the first listed repo.\n";
    print "\n";
    print "    [ --set-repoalias <name> ]\n";
    print "      Set/Overwrite alias name for the first listed repo.\n";
    print "\n";
    print "    [ --set-repoprio <number> ]\n";
    print "      Set/Overwrite priority for the first listed repo.\n";
    print "      Works with the smart packagemanager only\n";
    print "\n";
    print "    [ --add-repo <repo-path> --add-repotype <type> ]\n";
    print "      [ --add-repotype <type> ]\n";
    print "      [ --add-repoalias <name> ]\n";
    print "      [ --add-repoprio <number> ]\n";
    print "      Add the repository to the list of repos.\n";
    print "\n";
    print "    [ --ignore-repos ]\n";
    print "      Ignore all repos specified so-far, in XML or otherwise.\n";
    print "\n";
    print "    [ --logfile <filename> | terminal ]\n";
    print "      Write to the log file \`<filename>'\n";
    print "\n";
    print "    [ --gzip-cmd <cmd> ]\n";
    print "      Specify an alternate gzip command\n";
    print "\n";
    print "    [ --log-port <port-number> ]\n";
    print "      Set the log server port. By default port 9000 is used.\n";
    print "\n";
    print "    [ --package-manager <smart|zypper> ]\n";
    print "      Set the package manager to use for this image.\n";
    print "\n";
    print "    [ -A | --target-arch <i586|x86_64> ]\n";
    print "      Set a special target-architecture. This overrides the \n";
    print "      used architecture for the image-packages in zypp.conf.\n";
    print "      When used with smart this option doesn't have any effect.\n";
    print "\n";
    print "    [ --disk-start-sector <number> ]\n";
    print "      The start sector value for virtual disk based images.\n";
    print "      The default is 2048. For newer disks including SSD\n";
    print "      this is a reasonable default. In order to use the old\n";
    print "      style disk layout the value can be set to 32\n";
    print "\n";
    print "    [ --disk-sector-size <number> ]\n";
    print "      Overwrite the default 512 byte sector size value.\n";
    print "      This will influence the partition alignment\n";
    print "\n";
    print "    [ --disk-alignment <KBytes> ]\n";
    print "      Align the start of each partition to the specified\n";
    print "      value. By default 4096 Kbytes are used\n";
    print "\n";
    print "    [ --debug ]\n";
    print "      Prints a stack trace in case of internal errors\n";
    print "\n";
    print "    [ -v | --verbose <1|2|3> ]\n";
    print "      Controls the verbosity level for the instsource module\n";
    print "\n";
    print "    [ -y | --yes ]\n";
    print "      Answer any interactive questions with yes\n";
    print "\n";
    print "Image Preparation Options:\n";
    print "    [ -r | --root <image-root> ]\n";
    print "      Use the given directory as new image root path\n";
    print "\n";
    print "    [ --force-new-root ]\n";
    print "      Force creation of new root directory. If the directory\n";
    print "      already exists, it is deleted.\n";
    print "\n";
    print "Image Upgrade/Preparation Options:\n";
    print "    [ --add-package <package> ]\n";
    print "      Adds the given package name to the list of image packages.\n";
    print "\n";
    print "    [ --add-pattern <name> ]\n";
    print "      Adds the given pattern name to the list of image patters.\n";
    print "\n";
    print "    [ --del-package <package> ]\n";
    print "      Removes the given package by adding it the list of packages\n";
    print "      to become removed.\n";
    print "\n";
    print "Image Creation Options:\n";
    print "    [ -d | --destdir <destination-path> ]\n";
    print "      Specify destination directory to store the image file(s)\n";
    print "\n";
    print "    [ -t | --type <image-type> ]\n";
    print "      Specify the output image type. The selected type must be\n";
    print "      part of the XML description\n";
    print "\n";
    print "    [ -s | --strip ]\n";
    print "      Strip shared objects and executables.\n";
    print "\n";
    print "    [ --prebuiltbootimage <directory> ]\n";
    print "      search in <directory> for pre-built boot images\n";
    print "\n";
    print "    [ --archive-image ]\n";
    print "      When calling kiwi --create this option allows to pack\n";
    print "      the build result(s) into a tar archive\n";
    print "\n";
    print "    [ --isocheck ]\n";
    print "      in case of an iso image the checkmedia program generates\n";
    print "      a md5sum into the iso header. If the --isocheck option is\n";
    print "      specified a new boot menu entry will be generated which\n";
    print "      allows to check this media\n";
    print "\n";
    print "    [ --lvm ]\n";
    print "      use the logical volume manager for disk images\n";
    print "\n";
    print "    [ --fs-blocksize <number> ]\n";
    print "      Set the block size in Bytes. For ramdisk based ISO images\n";
    print "      a blocksize of 4096 bytes is required\n";
    print "\n";
    print "    [ --fs-journalsize <number> ]\n";
    print "      Set the journal size in MB for ext[23] based filesystems\n";
    print "      and in blocks if the reiser filesystem is used\n"; 
    print "\n";
    print "    [ --fs-inodesize <number> ]\n";
    print "      Set the inode size in Bytes. This option has no effect\n";
    print "      if the reiser filesystem is used\n";
    print "\n";
    print "    [ --fs-inoderatio <number> ]\n";
    print "      Set the bytes/inode ratio. This option has no\n";
    print "      effect if the reiser filesystem is used\n";
    print "\n";
    print "    [ --fs-max-mount-count <number> ]\n";
    print "      Set the number of mounts after which the filesystem will\n";
    print "      be checked for ext[234]. Set to 0 to disable checks.\n";
    print "\n";
    print "    [ --fs-check-interval <number> ]\n";
    print "      Set the maximal time between two filesystem checks for\n";
    print "      ext[234]. Set to 0 to disable time-dependent checks.\n";
    print "\n";
    print "    [ --fat-storage <size in MB> ]\n";
    print "      This option turns on the grub2 bootloader and makes\n";
    print "      the image to use LVM for the operating system. The size\n";
    print "      of the also set fat based bootpartition is set to the\n";
    print "      specified value. This is useful if the fat space is not\n";
    print "      only used for booting the system but also for custom data\n";
    print "      Therefore this option makes sense when building Windows\n";
    print "      friendly USB stick images\n";
    print "\n";
    print "    [ --partitioner <parted|fdasd> ]\n";
    print "      Select the tool to create partition tables. Supported are\n";
    print "      parted and fdasd (s390). By default parted is used\n";
    print "\n";
    print "    [ --check-kernel ]\n";
    print "      Activates check for matching kernels between boot and\n";
    print "      system image.\n";
    print "\n";
    print "    [ --mbrid <number>]\n";
    print "      Sets the disk id to the given value. The default is to\n";
    print "      generate a random id.\n";
    print "--\n";
    exit ($exit);
}

#==========================================
# listImage
#------------------------------------------
sub listImage {
    # ...
    # list known image descriptions and exit
    # ---
    my $gdata  = $global -> getKiwiConfig();
    my $system = $gdata->{System};
    my @images = ();
    if (opendir (my $FD,$system)) {
        @images = readdir ($FD); closedir ($FD);
    }
    my $templates = 0;
    foreach my $image (sort @images) {
        if ($image =~ /^\./) {
            next;
        }
        if (! -d "$system/$image") {
            next;
        }
        if ($image =~ /(iso|net|oem|vmx)boot/) {
            next;
        }
        my $controlFile = $locator -> getControlFile (
            "$system/$image"
        );
        if ($controlFile) {
            $kiwi -> info ("* \033[1;32m".$image."\033[m\017\n");
            my $xml = KIWIXML -> new (
                $system."/".$image,undef,undef,$cmdL
            );
            if (! $xml) {
                next;
            }
            my $version = $xml -> getPreferences() -> getVersion();
            $kiwi -> info ("Version: $version");
            $kiwi -> done();
            $templates++;
        }
    }
    if (! $templates) {
        $kiwi -> info ("No templates found");
        $kiwi -> done ();
    }
    exit 0;
}

#==========================================
# checkConfig
#------------------------------------------
sub checkConfig {
    # ...
    # Check the specified configuration. validate the
    # schema and apply the prepare runtime checks
    # ---
    my $config = shift;
    my $gdata  = $global -> getKiwiConfig();
    if (! -f $config) {
        $kiwi -> error (
            "Could not access specified file to check: $config"
        );
        $kiwi -> failed ();
        exit 1;
    }
    my $validator = KIWIXMLValidator -> new (
        $config,$gdata->{Revision},
        $gdata->{Schema},$gdata->{SchemaCVT}
    );
    if (! $validator) {
        exit 1;
    }
    my $isValid = $validator -> validate();
    if (! defined $isValid) {
        $kiwi -> error ('Validation failed');
        $kiwi -> failed ();
        exit 1;
    }
    my $configDir = dirname ($config);
    my $xml = KIWIXML -> new (
        $configDir,$cmdL->getBuildType(),undef,$cmdL
    );
    if (! $xml) {
        exit 1;
    }
    my $krc = KIWIRuntimeChecker -> new(
        $cmdL, $xml
    );
    if ((! $krc) || (! $krc -> prepareChecks())) {
        exit 1;
    }
    $kiwi -> info ('Validation passed');
    $kiwi -> done ();
    exit 0;
}

#==========================================
# cloneImage
#------------------------------------------
sub cloneImage {
    # ...
    # clone an existing image description by copying
    # the tree to the given destination the possibly
    # existing checksum will be removed as we assume
    # that the clone will be changed
    # ----
    my $clone      = shift;
    my $gdata      = $global -> getKiwiConfig();
    my $configName = $gdata->{ConfigName};
    my $system     = $gdata->{System};
    my $destination= $cmdL->getImageTargetDir();
    my %checklinks = ();
    #==========================================
    # Check destination definition
    #------------------------------------------
    if (! $destination) {
        $kiwi -> error  ("No destination directory specified");
        $kiwi -> failed ();
        kiwiExit (1);
    } else {
        $kiwi -> info ("Cloning image $clone -> $destination\n");
    }
    #==========================================
    # Evaluate image path or name 
    #------------------------------------------
    if (($clone !~ /^\//) && (! -d $clone)) {
        $clone = $system."/".$clone;
    }
    my $cfg = $clone."/".$configName;
    my $md5 = $destination."/.checksum.md5";
    if (! -f $cfg) {
        my @globsearch = glob ($clone."/*.kiwi");
        my $globitems  = @globsearch;
        if ($globitems == 0) {
            $kiwi -> error ("Cannot find control file: $cfg");
            $kiwi -> failed ();
            kiwiExit (1);
        } elsif ($globitems > 1) {
            $kiwi -> error ("Found multiple *.kiwi control files");
            $kiwi -> failed ();
            kiwiExit (1);
        } else {
            $cfg = pop @globsearch;
        }
    }
    #==========================================
    # Check if destdir exists or not 
    #------------------------------------------
    if (! -d $destination) {
        $cmdL->setDefaultAnswer("yes");
        my $dirCreated = $global -> createDirInteractive(
            $destination, $cmdL->getDefaultAnswer()
        );
        if (! defined $dirCreated) {
            kiwiExit (1);
        }
    } else {
        $kiwi -> error ("Destination $destination already exists");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    #==========================================
    # Copy path to destination 
    #------------------------------------------
    my $data = KIWIQX::qxx ("cp -a $clone/* $destination 2>&1");
    my $code = $? >> 8;
    if ($code != 0) {
        $kiwi -> error ("Failed to copy $clone: $data");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    #==========================================
    # find links with relative path pointer
    #------------------------------------------
    my $wref = findLinksRelative (\%checklinks);
    find({ wanted => $wref }, $destination);
    #==========================================
    # ...and fix them if needed due to clone cp
    #------------------------------------------
    foreach my $file (keys %checklinks) {
        my $dirn = $checklinks{$file};
        my ($src,$data,$code);
        $src = $clone."/".substr($file, length($destination."/"));
        $src = Cwd::abs_path ($src);
        unlink $file;
        $data = KIWIQX::qxx ("cp -L $src $dirn 2>&1");
        $code = $? >> 8;
        if ($code != 0) {
            $kiwi -> error ("Failed to fix-up link $src: $data");
            $kiwi -> failed ();
            kiwiExit (1);
        }
    }
    #==========================================
    # Remove checksum 
    #------------------------------------------
    if (-f $md5) {
        KIWIQX::qxx ("rm -f $md5 2>&1");
    }
    kiwiExit (0);
    return;
}

#==========================================
# findLinksRelative
#------------------------------------------
sub findLinksRelative {
    # ...
    # find symlinks in the File::Find given directory whose
    # pointer is specified as a relative path. Such links
    # might be relinked if they have been moved
    # ---
    my $filehash = shift;
    return sub {
        my $file   = $File::Find::name;
        my $dirn   = $File::Find::dir;
        my $fixlink = 0;
        if (-l $file) {
            if (! File::Spec->file_name_is_absolute (readlink $file)) {
                $fixlink = 1;
            }
        }
        if ($fixlink) {
            $filehash->{$file} = $dirn;
        }
    }
}

#==========================================
# exit
#------------------------------------------
sub kiwiExit {
    my $code = shift;
    my $good = "KIWI exited successfully\n";
    my $bad  = "KIWI exited with error(s)\n";
    #==========================================
    # Reformat log file for human readers...
    #------------------------------------------
    $kiwi -> info("Closing session with ecode: $code\n");
    $kiwi -> setLogHumanReadable();
    #==========================================
    # Check for backtrace and clean flag...
    #------------------------------------------
    if ($code != 0) {
        if ($cmdL -> getDebug()) {
            $kiwi -> printBackTrace();
        }
        $kiwi -> error($bad);
        if ($kiwi -> fileLogging()) {
            $kiwi -> setLogFile("terminal");
            $kiwi -> info($bad);
        }
    } else {
        $kiwi -> info($good);
        if ($kiwi -> fileLogging()) {
            $kiwi -> setLogFile("terminal");
            $kiwi -> info($good);
        }
    }
    #==========================================
    # Move process log to final logfile name...
    #------------------------------------------
    $kiwi -> finalizeLog();
    #==========================================
    # Cleanup and exit now...
    #------------------------------------------
    cleanup();
    exit $code;
}

#==========================================
# quit
#------------------------------------------
sub quit {
    # ...
    # signal received, exit safely
    # ---
    $kiwi -> reopenRootChannel();
    $kiwi -> note ("\n*** $$: Received signal $_[0] ***\n");
    kiwiExit (1);
    return;
}

#==========================================
# cleanup
#------------------------------------------
sub cleanup {
    # ...
    # call object destructors
    # ---
    if ($kic) {
        undef $kic;
    }
    if ($icache) {
        undef $icache;
    }
    return;
}

#==========================================
# revision
#------------------------------------------
sub revision {
    my $gdata = $global -> getKiwiConfig();
    my $rev  = "unknown";
    if (open my $FD,'<',$gdata->{Revision}) {
        $rev = <$FD>; close $FD;
    }
    chomp $rev;
    return $rev;
}

#==========================================
# version
#------------------------------------------
sub version {
    # ...
    # Version information
    # ---
    my $exit  = shift;
    my $gdata = $global -> getKiwiConfig();
    if (! defined $exit) {
        $exit = 0;
    }
    my $rev = revision();
    $kiwi -> info ("Version:\n");
    $kiwi -> info ("--> vnr: $gdata->{Version}\n");
    $kiwi -> info ("--> git: $rev\n");
    exit ($exit);
}

#==========================================
# getXMLInfo
#------------------------------------------
sub getXMLInfo {
    my $config = shift;
    $cmdL -> setConfigDir($config);
    my $info = KIWIXMLInfo -> new ($cmdL);
    if (! $info) {
        kiwiExit (1);
    }
    my $res = $info -> printXMLInfo (
        $cmdL -> getXMLInfoSelection()
    );
    if (! $res) {
        kiwiExit (1);
    }
    kiwiExit (0);
    return;
}

#==========================================
# createPassword
#------------------------------------------
sub createPassword {
    # ...
    # Create a crypted password which can be used in the xml descr.
    # users sections. The crypt() call requires root rights because
    # dm-crypt is used to access the crypto pool
    # ----
    my $pwd = shift;
    my @legal_enc = ('.', '/', '0'..'9', 'A'..'Z', 'a'..'z');
    my $word2 = 2;
    my $word1 = 1;
    my $tmp = (time + $$) % 65536;
    my $salt;
    srand ($tmp);
    $salt = $legal_enc[sprintf "%u", rand (@legal_enc)];
    $salt.= $legal_enc[sprintf "%u", rand (@legal_enc)];
    if (defined $pwd) {
        $word1 = $word2 = $pwd;
    }
    while ($word1 ne $word2) {
        $kiwi -> info ("Enter Password: ");
        system "stty -echo";
        chomp ($word1 = <>);
        system "stty echo";
        $kiwi -> done ();
        $kiwi -> info ("Reenter Password: ");
        system "stty -echo";
        chomp ($word2 = <>);
        system "stty echo";
        if ( $word1 ne $word2 ) {
            $kiwi -> failed ();
            $kiwi -> info ("*** Passwords differ, please try again ***");
            $kiwi -> failed ();
        }
    }
    my $encrypted = crypt ($word1, $salt);
    if (defined $pwd) {
        return $encrypted;
    }
    $kiwi -> done ();
    $kiwi -> info ("Your password:\n\t$encrypted\n");
    kiwiExit (0);
    return;
}

#==========================================
# createHash
#------------------------------------------
sub createHash {
    # ...
    # Sign your image description with a md5 sum. The created
    # file .checksum.md5 is checked on runtime with the md5sum
    # command
    # ----
    my $idesc = shift;
    $kiwi -> info ("Creating MD5 sum for $idesc...");
    if (! -d $idesc) {
        $kiwi -> failed ();
        $kiwi -> error  ("Not a directory: $idesc: $!");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    if (! $locator -> getControlFile ($idesc)) {
        $kiwi -> failed ();
        $kiwi -> error  ("Not a kiwi description: no xml description found");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    my $cmd  = "find -L -type f | grep -v .svn | grep -v .checksum.md5";
    my $status = KIWIQX::qxx (
        "cd $idesc && $cmd | xargs md5sum > .checksum.md5"
    );
    my $result = $? >> 8;
    if ($result != 0) {
        $kiwi -> error  ("Failed creating md5 sum: $status: $!");
        $kiwi -> failed ();
    }
    $kiwi -> done();
    kiwiExit (0);
    return;
}

#==========================================
# createInstSource
#------------------------------------------
sub createInstSource {
    # /.../
    # create instsource requires the module "KIWICollect.pm".
    # If it is not available, the option cannot be used.
    # kiwi then issues a warning and exits.
    # ----
    my $idesc = shift;
    my $vlevel= shift;
    $kiwi -> deactivateBackTrace();
    my $mod = "KIWICollect";
    eval "require $mod"; ## no critic
    if($@) {
        $kiwi->error("Module <$mod> is not available!");
        kiwiExit (3);
    }
    else {
        $kiwi->info("Module KIWICollect loaded successfully...");
        $kiwi->done();
    }
    $kiwi -> info ("Reading image description [InstSource]...\n");
    my $xml = KIWIXML -> new (
        $idesc,undef,undef,$cmdL
    );
    if (! defined $xml) {
        kiwiExit (1);
    }
    my $pkgMgr = $cmdL -> getPackageManager();
    if ($pkgMgr) {
        $xml -> setPackageManager($pkgMgr);
    }
    #==========================================
    # Initialize installation source tree
    #------------------------------------------
    my $root = $locator -> createTmpDirectory (
        undef, $cmdL->getRootTargetDir(), $cmdL
    );
    if (! defined $root) {
        $kiwi -> error ("Couldn't create instsource root");
        $kiwi -> failed ();
        kiwiExit (1);
    }
    #==========================================
    # Create object...
    #------------------------------------------
    my $collect = KIWICollect -> new ( $xml, $root, $vlevel,$cmdL );
    if (! defined( $collect) ) {
        $kiwi -> error( "Unable to create KIWICollect module." );
        $kiwi -> failed ();
        kiwiExit( 1 );
    }
    if (! defined( $collect -> Init () ) ) {
        $kiwi -> error( "Object initialisation failed!" );
        $kiwi -> failed ();
        kiwiExit( 1 );
    }
    #==========================================
    # Call the *CENTRAL* method for it...
    #----------------------------------------
    my $ret = $collect -> mainTask ();
    if ( $ret != 0 ) {
        $kiwi -> warning( "KIWICollect had runtime error." );
        $kiwi -> skipped ();
        kiwiExit ( $ret );
    }
    $kiwi->info( "KIWICollect completed successfully." );
    $kiwi->done();
    kiwiExit (0);
    return;
}

main();

# vim: set noexpandtab:
